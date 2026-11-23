require_relative "wechat_payments_test"

class WechatPaymentsTest
  test "audit optional v3 fields on an unpaid query and a processing refund" do
    prepare("v3")
    response_data = payment_data("v3", "NOTPAY")
    stub_payment_query("v3") { response_data }
    [ {}, { "success_time" => nil }, { "success_time" => "", "transaction_id" => "", "trade_type" => "", "payer" => "",
      "amount" => { "total" => 2000, "currency" => nil, "payer_total" => "" } } ].each do |fields|
      response_data = payment_data("v3", "NOTPAY").merge(fields)
      assert_equal "NOTPAY", @payments.query(PAYMENT)[:state]
    end
    response_data = payment_data("v3", "NOTPAY").merge("success_time" => "invalid")
    assert_raises(Payments::InvalidResult) { @payments.query(PAYMENT) }
    assert_equal 0, @order.credits
    [ false, "invalid", "2026-02-30T00:00:00+08:00" ].each do |bad|
      response_data = payment_data("v3", "NOTPAY").merge("success_time" => bad)
      assert_raises(Payments::InvalidResult) { @payments.query(PAYMENT) }
    end
    response_data = payment_data("v3")
    @payments.query(PAYMENT)
    @order.reserve(REFUND, 500)
    data = refund_data("v3", 500, "PROCESSING")
    stub_refund_query("v3") { data }
    [ {}, { "success_time" => nil }, { "success_time" => "" } ].each do |fields|
      data = refund_data("v3", 500, "PROCESSING").merge(fields)
      assert_equal "PROCESSING", @payments.query_refund(PAYMENT, refund_no: REFUND)[:state]
    end
  end

  test "audit alternate verifier follows the serial in the response" do
    prepare("v3")
    alternate = OpenSSL::PKey::RSA.generate(2048)
    second_id = "PUB_KEY_ID_7890"
    settings = WechatPaySettings.new
    assert settings.save({ "revision" => settings.revision, "backup_verification_id" => second_id,
      "backup_verification_pem" => alternate.public_key.to_pem }, actor: nil)
    stub_payment_query("v3") { payment_data("v3") }
    primary_id, primary_key = @key_id, @wechat_key
    [ [ second_id, alternate ], [ primary_id, primary_key ], [ second_id, alternate ] ].each do |id, key|
      @key_id, @wechat_key = id, key
      assert_equal "SUCCESS", @payments.query(PAYMENT)[:state]
    end
    assert_equal 1, @order.credits
  end

  %w[SYSTEMERROR BIZERR_NEED_RETRY FREQUENCY_LIMITED].each do |code|
    test "audit v2 #{code} reconciles the reserved refund" do
      prepare("v2")
      notify("v2", "payment", payment_data("v2"))
      @order.reserve(REFUND, 500)
      applications, queries = [], 0
      stub_wechat("v2", :post, "/secapi/pay/refund") do |req|
        applications << req.values_at("out_refund_no", "refund_fee")
        { "result_code" => "FAIL", "err_code" => code }
      end
      stub_refund_query("v2") do
        queries += 1
        refund_data("v2", 500, "SUCCESS", query: true).merge("coupon_refund_fee_1" => "0")
      end
      assert_equal "SUCCESS", @payments.refund(PAYMENT, refund_no: REFUND)[:state]
      assert_equal [ [ [ REFUND, "500" ] ], 1 ], [ applications, queries ]
      assert_equal [ 500, 500 ], [ @order.refunded, @order.refunded_cash ]
    end
  end

  %w[CLOSED ABNORMAL].each do |state|
    test "audit v3 synchronous #{state} reaches the refund receiver" do
      prepare("v3")
      notify("v3", "payment", payment_data("v3"))
      @order.reserve(REFUND, 500)
      stub_wechat("v3", :post, "/v3/refund/domestic/refunds") { refund_data("v3", 500, state) }
      assert_equal state, @payments.refund(PAYMENT, refund_no: REFUND)[:state]
      assert_equal state, @order.refund(REFUND)["state"]
      assert_equal 0, @order.refunded
      if state == "ABNORMAL"
        assert_raises(RuntimeError) { @order.reserve(REFUND.succ, 1501) }
      else
        assert_equal 2000, @order.reserve(REFUND.succ, 2000)["refund_cents"]
        late = refund_data("v3", 500, "ABNORMAL").merge("mchid" => @merchant_id, "refund_status" => "ABNORMAL")
        notify("v3", "refund", late)
        assert_response :no_content
        assert_equal "CLOSED", @order.refund(REFUND)["state"]
      end
    end
  end

  test "audit cashier queries before refreshing a nearly expired prepay" do
    prepare("v3")
    events = []
    stub_wechat("v3", :post, "/v3/pay/transactions/jsapi") do |req|
      events << [ :prepay, req.fetch("out_trade_no"), req.fetch("description") ]
      { "prepay_id" => "wx_#{events.length}" }
    end
    stub_payment_query("v3") { events << [ :query, PAYMENT ]; payment_data("v3", "NOTPAY") }
    @payment.merge!(checkout.except("payment_params"))
    @payment["prepay_expires_at"] = 4.minutes.from_now.iso8601
    result = @payments.checkout(PAYMENT, app: @mini_program, identity: @identity, description: "改过的说明")
    assert_equal [ [ :prepay, PAYMENT, "支付底座测试" ], [ :query, PAYMENT ], [ :prepay, PAYMENT, "支付底座测试" ] ], events
    assert_equal "wx_3", result["prepay_id"]
  end

  [ 429, 503 ].each do |status|
    test "v3 unsigned #{status} followed by unsigned not found holds the same reservation" do
      prepare("v3")
      notify("v3", "payment", payment_data("v3"))
      @order.reserve(REFUND, 500)
      applications, queries = [], 0
      @stubs.post("/v3/refund/domestic/refunds") do |req|
        applications << JSON.parse(req.body).fetch("out_refund_no")
        [ status, {}, "unverified gateway response" ]
      end
      @stubs.get("/v3/refund/domestic/refunds/#{REFUND}") do
        queries += 1
        [ 404, {}, '{"code":"RESOURCE_NOT_EXISTS"}' ]
      end
      assert_raises(Payments::Unavailable) { @payments.refund(PAYMENT, refund_no: REFUND) }
      assert_equal [ [ REFUND ], 1 ], [ applications, queries ]
      assert_equal [ "PROCESSING", 500, nil ], @order.refund(REFUND).values_at("state", "refund_cents", "payer_refund_cents")
      assert_raises(RuntimeError) { @order.reserve(REFUND.succ, 1501) }
      assert_raises(Payments::Unavailable) { @payments.refund(PAYMENT, refund_no: REFUND) }
      assert_equal [ [ REFUND ], 2 ], [ applications, queries ]
    end
  end

  test "v3 unsigned 503 after acceptance reconciles exactly once and confirms the cash" do
    prepare("v3")
    notify("v3", "payment", payment_data("v3"))
    @order.reserve(REFUND, 500)
    events = []
    @stubs.post("/v3/refund/domestic/refunds") do |req|
      events << [ :submit, JSON.parse(req.body).fetch("out_refund_no") ]
      [ 503, { "content-type" => "text/html" }, "<p>Unavailable</p>" ]
    end
    stub_refund_query("v3") do
      events << [ :lookup, REFUND ]
      refund_data("v3", 500, "SUCCESS").tap { |r| r["amount"]["payer_refund"] = 500 }
    end
    result = @payments.refund(PAYMENT, refund_no: REFUND)
    assert_equal [ [ :submit, REFUND ], [ :lookup, REFUND ] ], events
    assert_equal [ "SUCCESS", REFUND_ID, 500, 500 ], [ result[:state], result[:refund_id], @order.refunded, @order.refunded_cash ]
  end

  test "v3 invalid signature on a gateway response cannot change refund state" do
    prepare("v3")
    notify("v3", "payment", payment_data("v3"))
    @order.reserve(REFUND, 500)
    @stubs.post("/v3/refund/domestic/refunds") { [ 503, v3_headers("different"), "unavailable" ] }
    assert_raises(Payments::InvalidResult) { @payments.refund(PAYMENT, refund_no: REFUND) }
    assert_equal [ "PROCESSING", 0, 0 ], [ @order.refund(REFUND)["state"], @order.refunded, @order.refunded_cash ]
  end

  test "near-expiry prepay returned unchanged by WeChat keeps its original deadline" do
    prepare("v3")
    @payment.merge!("prepay_id" => "same", "prepay_expires_at" => 4.minutes.from_now.iso8601)
    expiry = @payment["prepay_expires_at"]
    stub_payment_query("v3") { payment_data("v3", "NOTPAY") }
    stub_wechat("v3", :post, "/v3/pay/transactions/jsapi") { { "prepay_id" => "same" } }
    assert_raises(Payments::Unavailable) { checkout }
    assert_equal expiry, @payment["prepay_expires_at"]
  end

  test "unknown prepay only resubmits after signed order not found" do
    prepare("v3")
    path = "/v3/pay/transactions/out-trade-no/#{PAYMENT}?mchid=#{@merchant_id}"
    queries, submissions = 0, 0
    stub_wechat("v3", :post, "/v3/pay/transactions/jsapi") do
      submissions += 1
      raise Faraday::TimeoutError if submissions == 1
      { "prepay_id" => "recovered" }
    end
    assert_raises(Payments::Unavailable) { checkout }
    @stubs.get(path) do
      queries += 1
      raw = JSON.generate(code: "ORDER_NOT_EXIST")
      [ 404, queries == 1 ? {} : v3_headers(raw), raw ]
    end
    assert_raises(Payments::Unavailable) { checkout }
    assert_equal [ 1, 1 ], [ submissions, queries ]
    assert_equal "recovered", checkout["prepay_id"]
    assert_equal [ 2, 2 ], [ submissions, queries ]
  end

  [ 400, 503 ].each do |status|
    test "v3 lost close with unsigned #{status} checks the original number and empty optional fields" do
      prepare("v3")
      state, queries, closes = "NOTPAY", 0, 0
      stub_payment_query("v3") do
        queries += 1
        payment_data("v3", state).merge("success_time" => "", "transaction_id" => "", "trade_type" => "", "payer" => nil, "amount" => {})
      end
      @stubs.post("/v3/pay/transactions/out-trade-no/#{PAYMENT}/close") do
        state = "CLOSED"
        closes += 1
        [ status, {}, '{"code":"ORDER_PAID"}' ]
      end
      assert_equal "CLOSED", @payments.close(PAYMENT)[:state]
      assert_equal [ 2, 1, true, 0 ], [ queries, closes, @payment.fetch("closed"), @order.credits ]
    end
  end

  test "v3 close confirms CLOSED for omitted null and empty optional data" do
    prepare("v3")
    [ :omit, nil, "" ].each do |value|
      number = (PAYMENT.to_i + 1 + [ :omit, nil, "" ].index(value)).to_s
      receiver = BusinessOrder.new(@payment.merge("payment_no" => number))
      state = "NOTPAY"
      stub_wechat("v3", :get, "/v3/pay/transactions/out-trade-no/#{number}?mchid=#{@merchant_id}") do
        result = payment_data("v3", state).merge("out_trade_no" => number)
        result.merge!(%w[success_time transaction_id trade_type payer amount].index_with { value }) unless value == :omit
        result
      end
      stub_wechat("v3", :post, "/v3/pay/transactions/out-trade-no/#{number}/close", status: 204) { state = "CLOSED"; {} }
      assert_equal "CLOSED", Payments.new(receiver: receiver).close(number)[:state]
      assert receiver.payment_context.fetch("closed")
    end
  end

  test "v2 parses empty optional XML and rejects malformed nonempty values" do
    prepare("v2")
    data = payment_data("v2", "NOTPAY").merge(%w[time_end trade_type fee_type transaction_id total_fee openid cash_fee].index_with { "" })
    stub_payment_query("v2") { data }
    assert_equal "NOTPAY", @payments.query(PAYMENT)[:state]
    %w[time_end trade_type transaction_id total_fee openid cash_fee].each do |field|
      data[field] = "invalid"
      assert_raises(Payments::InvalidResult) { @payments.query(PAYMENT) }
      data[field] = ""
    end
    assert_equal 0, @order.credits
  end

  test "v3 authenticated notification accepts omitted null or empty associated data" do
    prepare("v3")
    [ :omit, nil, "", 77 ].each do |associated|
      body, headers = notification_packet("v3", "payment", payment_data("v3"), associated_data: associated)
      post api_wechat_payment_notification_path(version: "v3", config_ref: @payment["config_ref"], kind: "payment"), params: body, headers: headers
      assert_response(associated == 77 ? :bad_request : :no_content)
    end
    assert_equal 1, @order.credits
  end

  test "v2 only retries after signed not found with the same refund number and amount" do
    prepare("v2")
    notify("v2", "payment", payment_data("v2"))
    @order.reserve(REFUND, 500)
    events = []
    stub_wechat("v2", :post, "/secapi/pay/refund") do |req|
      events << [ :submit, req.fetch("out_refund_no"), req.fetch("refund_fee") ]
      events.one? ? { "result_code" => "FAIL", "err_code" => "BIZERR_NEED_RETRY" } : refund_data("v2", 500, "PROCESSING")
    end
    stub_refund_query("v2") { events << [ :lookup, REFUND ]; { "result_code" => "FAIL", "err_code" => "REFUNDNOTEXIST" } }
    assert_raises(Payments::Unavailable) { @payments.refund(PAYMENT, refund_no: REFUND) }
    assert_equal "PROCESSING", @order.refund(REFUND)["state"]
    assert_raises(RuntimeError) { @order.reserve(REFUND.succ, 1501) }
    assert_equal "PROCESSING", @payments.refund(PAYMENT, refund_no: REFUND)[:state]
    stub_refund_query("v2") { events << [ :lookup, REFUND ]; refund_data("v2", 500, "SUCCESS", query: true).merge("cash_refund_fee_1" => "500") }
    @payments.refund(PAYMENT, refund_no: REFUND)
    submit, lookup = [ :submit, REFUND, "500" ], [ :lookup, REFUND ]
    assert_equal [ submit, lookup, lookup, submit, lookup ], events
    assert_equal [ 1, 500, 500 ], [ @order.refunds.size, @order.refunded, @order.refunded_cash ]
  end

  test "v3 accepted success waits for confirmation and ignores duplicate or late states" do
    prepare("v3")
    notify("v3", "payment", payment_data("v3"))
    @order.reserve(REFUND, 500)
    data = refund_data("v3", 500, "SUCCESS")
    data["amount"]["payer_refund"] = 500
    stub_wechat("v3", :post, "/v3/refund/domestic/refunds") { data }
    accepted = @payments.refund(PAYMENT, refund_no: REFUND)
    assert_equal [ "SUCCESS", "PROCESSING" ], accepted.values_at(:acceptance_state, :state)
    assert_equal [ 0, 0 ], [ @order.refunded, @order.refunded_cash ]
    stub_refund_query("v3") { data }
    @payments.query_refund(PAYMENT, refund_no: REFUND)
    %w[SUCCESS ABNORMAL CLOSED SUCCESS].each do |state|
      notify("v3", "refund", data.except("status").merge("mchid" => @merchant_id, "refund_status" => state))
      assert_response :no_content
    end
    assert_equal [ "SUCCESS", 500, 500 ], [ @order.refund(REFUND)["state"], @order.refunded, @order.refunded_cash ]
  end

  %w[v2 v3].each do |version|
    test "#{version} rejects invalid signatures on successful refund responses and notifications" do
      prepare(version)
      notify(version, "payment", payment_data(version))
      @order.reserve(REFUND, 500)
      v2 = version == "v2"
      bad_response = ->(data) do
        raw = v2 ? signed_xml(data).sub("<sign>", "<sign>0") : JSON.generate(data)
        [ 200, v2 ? {} : v3_headers(raw + " "), raw ]
      end
      @stubs.post(v2 ? "/secapi/pay/refund" : "/v3/refund/domestic/refunds") { bad_response.call(refund_data(version, 500, "SUCCESS")) }
      assert_raises(Payments::InvalidResult) { @payments.refund(PAYMENT, refund_no: REFUND) }
      @stubs.public_send(v2 ? :post : :get, v2 ? "/pay/refundquery" : "/v3/refund/domestic/refunds/#{REFUND}") do
        bad_response.call(refund_data(version, 500, "SUCCESS", query: true))
      end
      assert_raises(Payments::InvalidResult) { @payments.query_refund(PAYMENT, refund_no: REFUND) }
      data = refund_data(version, 500, "SUCCESS")
      if v2
        notify(version, "refund", data)
      else
        notify(version, "refund", data.merge("mchid" => @merchant_id, "refund_status" => "SUCCESS")) { |raw, h| [ raw, h.merge(v3_headers(raw + " ")) ] }
      end
      assert_response :bad_request
      assert_equal [ "PROCESSING", nil, 0, 0 ], [ @order.refund(REFUND)["state"], @order.refund(REFUND)["refund_id"], @order.refunded, @order.refunded_cash ]
    end

    test "#{version} lost prepay queries first and never reorders paid or closed transactions" do
      prepare(version)
      state, requests, queries = "NOTPAY", [], 0
      stub_payment_query(version) { queries += 1; payment_data(version, state) }
      stub_wechat(version, :post, version == "v2" ? "/pay/unifiedorder" : "/v3/pay/transactions/jsapi") do |req|
        requests << req.except("nonce_str", "sign")
        raise Faraday::TimeoutError if requests.one?
        { "trade_type" => "JSAPI", "prepay_id" => "wx_recovered" }
      end
      assert_raises(Payments::Unavailable) { checkout }
      assert_equal "wx_recovered", @payments.checkout(PAYMENT, app: @mini_program, identity: @identity)["prepay_id"]
      assert_equal [ 2, 1 ], [ requests.size, queries ]
      assert_equal requests.first, requests.last
      assert_equal "wx_recovered", checkout["prepay_id"]
      assert_equal [ 2, 1 ], [ requests.size, queries ]
      @payment["prepay_expires_at"] = 1.minute.from_now.iso8601
      unpaid_snapshot = @payment.deep_dup
      %w[SUCCESS CLOSED].each do |terminal|
        state = terminal
        receiver = BusinessOrder.new(unpaid_snapshot.deep_dup)
        assert_raises(Payments::Error) { Payments.new(receiver: receiver).checkout(PAYMENT, app: @mini_program, identity: @identity) }
        assert_equal terminal == "SUCCESS" ? 1 : 0, receiver.credits
      end
      assert_equal [ 2, 3 ], [ requests.size, queries ]
    end
  end
end

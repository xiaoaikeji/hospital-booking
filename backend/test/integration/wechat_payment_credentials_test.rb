require_relative "wechat_payments_test"

class WechatPaymentsTest
  def update_payment_settings(fields)
    settings = WechatPaySettings.new
    assert settings.save(fields.merge("revision" => settings.revision), actor: nil), settings.errors.full_messages
  end

  %w[v2 v3].each do |version|
    test "#{version} cleared settings with only a deployment merchant still serve its old orders" do
      env = %w[WECHAT_PAY_MERCHANT_ID WECHAT_PAY_VERSION].index_with { |field| ENV[field] }
      ENV["WECHAT_PAY_MERCHANT_ID"] = @merchant_id
      ENV["WECHAT_PAY_VERSION"] = ("v2" if version == "v2")
      prepare(version)
      @merchant_key = OpenSSL::PKey::RSA.generate(2048)
      @certificate = payment_certificate(@merchant_key, @merchant_id)
      @v2_key = SecureRandom.hex(16)
      configure(version)
      update_payment_settings("clear_settings" => "1")
      assert_raises(WechatPaySettings::Invalid) do
        @payments.prepare(app: @mini_program, identity: @identity, payment_no: PAYMENT.succ, amount_cents: 2000)
      end
      stub_payment_query(version) { payment_data(version) }
      assert_equal "SUCCESS", @payments.query(PAYMENT)[:state]
      notify(version, "payment", payment_data(version))
      assert_response(version == "v2" ? :ok : :no_content)
      assert_equal "SUCCESS", Hash.from_xml(response.body).dig("xml", "return_code") if version == "v2"
      assert_equal 1, @order.credits
      @order.reserve(REFUND, 500)
      applications, lookups = [], 0
      stub_wechat(version, :post, version == "v2" ? "/secapi/pay/refund" : "/v3/refund/domestic/refunds") do |request|
        applications << request.fetch("out_refund_no")
        refund_data(version, 500, "PROCESSING")
      end
      assert_equal "PROCESSING", @payments.refund(PAYMENT, refund_no: REFUND)[:state]
      stub_refund_query(version) do
        lookups += 1
        data = refund_data(version, 500, "SUCCESS", query: true)
        cash = version == "v2" ? { "cash_refund_fee_1" => "500" } : { "amount" => { "payer_refund" => 500 } }
        data.deep_merge(cash)
      end
      assert_equal "SUCCESS", @payments.query_refund(PAYMENT, refund_no: REFUND)[:state]
      assert_equal [ [ REFUND ], 1, 500 ], [ applications, lookups, @order.refunded_cash ]
    ensure
      env.each { |field, original| ENV[field] = original }
    end
  end

  test "v2 collects without TLS, then refunds that same order after adding and rotating its certificate" do
    update_payment_settings(payment_settings("v2").except(*WechatPaySettings::V2_TLS))
    @payment = Payments.new.prepare(app: @mini_program, identity: @identity, payment_no: PAYMENT, amount_cents: 2000)
    @order = BusinessOrder.new(@payment)
    @payments = Payments.new(receiver: @order)
    stub_wechat("v2", :post, "/pay/unifiedorder") { { "trade_type" => "JSAPI", "prepay_id" => "before-cert" } }
    assert_equal "before-cert", checkout["prepay_id"]
    states = { PAYMENT => "NOTPAY", PAYMENT.succ => "NOTPAY" }
    stub_wechat("v2", :post, "/pay/orderquery") do |req|
      number = req.fetch("out_trade_no")
      payment_data("v2", states.fetch(number)).merge("out_trade_no" => number)
    end
    assert_equal "NOTPAY", @payments.query(PAYMENT)[:state]
    unpaid = BusinessOrder.new(@payment.merge("payment_no" => PAYMENT.succ))
    stub_wechat("v2", :post, "/pay/closeorder") { |req| states[req.fetch("out_trade_no")] = "CLOSED"; {} }
    assert_equal "CLOSED", Payments.new(receiver: unpaid).close(PAYMENT.succ)[:state]
    states[PAYMENT] = "SUCCESS"
    @payments.query(PAYMENT)
    @order.reserve(REFUND, 500)
    stub_refund_query("v2") { { "result_code" => "FAIL", "err_code" => "REFUNDNOTEXIST" } }
    assert_raises(Payments::RefundNotFound) { @payments.query_refund(PAYMENT, refund_no: REFUND) }
    error = assert_raises(WechatPaySettings::Invalid) { @payments.refund(PAYMENT, refund_no: REFUND) }
    assert_equal "v2_certificate", error.field
    assert_nil @order.refund(REFUND)["attempted"]
    configure("v2")
    old_cert = @certificate
    @merchant_key = OpenSSL::PKey::RSA.generate(2048)
    @certificate = payment_certificate(@merchant_key, @merchant_id)
    configure("v2")
    refute_equal old_cert.serial, @certificate.serial
    applications = 0
    stub_wechat("v2", :post, "/secapi/pay/refund") do |req|
      applications += 1
      assert_equal REFUND, req["out_refund_no"]
      refund_data("v2", 500, "PROCESSING")
    end
    assert_equal "PROCESSING", @payments.refund(PAYMENT, refund_no: REFUND)[:state]
    stub_refund_query("v2") { refund_data("v2", 500, "SUCCESS", query: true).merge("cash_refund_fee_1" => "500") }
    assert_equal 500, @payments.query_refund(PAYMENT, refund_no: REFUND)[:payer_refund_cents]
    assert_equal [ 1, 500 ], [ applications, @order.refunded_cash ]
    travel_to(@certificate.not_after + 1.day) do
      assert_equal "SUCCESS", @payments.query(PAYMENT)[:state]
      @order.reserve(REFUND.succ, 100)
      expired = assert_raises(WechatPaySettings::Invalid) { @payments.refund(PAYMENT, refund_no: REFUND.succ) }
      assert_match(/有效期/, expired.message)
    end
  end

  test "legacy v3 order uses the renewed merchant signer for every operation after switching merchant and version" do
    prepare("v3")
    original_merchant, revoked = @merchant_id, @certificate
    # A pre-upgrade order only had the encrypted archive and no registry or attempt flag.
    Setting.where("key LIKE 'wechat_pay_current:%'").delete_all
    @payment.delete("prepay_attempted")
    @merchant_key = OpenSSL::PKey::RSA.generate(2048)
    @certificate = payment_certificate(@merchant_key, original_merchant)
    configure("v3")
    current = @certificate
    @merchant_id = "1900000002"
    @v2_key = SecureRandom.hex(16)
    update_payment_settings(payment_settings("v2").except(*WechatPaySettings::V2_TLS))
    fresh = Payments.new.prepare(app: @mini_program, identity: @identity, payment_no: PAYMENT.succ, amount_cents: 2000)
    assert_equal [ "v2", @merchant_id ], fresh.values_at("version", "merchant_id")
    @merchant_id = original_merchant
    state, seen = "NOTPAY", []
    path = "/v3/pay/transactions/out-trade-no/#{PAYMENT}?mchid=#{original_merchant}"
    @stubs.get(path) do |request|
      auth = request.request_headers.fetch("Authorization").scan(/(\w+)="([^"]+)"/).to_h
      seen << [ auth["mchid"], auth["serial_no"] ]
      message = [ "GET", request.url.request_uri, auth["timestamp"], auth["nonce_str"], "", "" ].join("\n")
      ok = auth["serial_no"] == current.serial.to_s(16).upcase && current.public_key.verify("SHA256", Base64.strict_decode64(auth["signature"]), message)
      raw = JSON.generate(ok ? payment_data("v3", state) : { "code" => "SIGN_ERROR" })
      [ ok ? 200 : 401, v3_headers(raw), raw ]
    end
    # Prove the mock actively rejects the pre-upgrade credentials.
    old_config = WechatPaySettings.archived!(@payment.fetch("config_ref"))
    assert_equal revoked.serial.to_s(16).upcase, old_config["merchant_serial"]
    assert_raises(Payments::ChannelError) { Wechat::PaymentV3Client.new(old_config).query(@payment) }
    stub_wechat("v3", :post, "/v3/pay/transactions/jsapi") { { "prepay_id" => "renewed-signer" } }
    params = checkout.fetch("payment_params")
    message = [ @mini_program.appid, *params.values_at("timeStamp", "nonceStr", "package"), "" ].join("\n")
    assert current.public_key.verify("SHA256", Base64.strict_decode64(params.fetch("paySign")), message)
    refute revoked.public_key.verify("SHA256", Base64.strict_decode64(params.fetch("paySign")), message)
    unpaid_no = PAYMENT.succ.succ
    unpaid = BusinessOrder.new(@payment.merge("payment_no" => unpaid_no))
    unpaid_state = "NOTPAY"
    stub_wechat("v3", :get, "/v3/pay/transactions/out-trade-no/#{unpaid_no}?mchid=#{original_merchant}") do
      payment_data("v3", unpaid_state).merge("out_trade_no" => unpaid_no)
    end
    stub_wechat("v3", :post, "/v3/pay/transactions/out-trade-no/#{unpaid_no}/close", status: 204) { unpaid_state = "CLOSED"; {} }
    assert_equal "CLOSED", Payments.new(receiver: unpaid).close(unpaid_no)[:state]
    state = "SUCCESS"
    @payments.query(PAYMENT)
    notify("v3", "payment", payment_data("v3"))
    assert_response :no_content
    @order.reserve(REFUND, 500)
    stub_wechat("v3", :post, "/v3/refund/domestic/refunds") { refund_data("v3", 500, "PROCESSING") }
    assert_equal "PROCESSING", @payments.refund(PAYMENT, refund_no: REFUND)[:state]
    stub_refund_query("v3") { refund_data("v3", 500, "SUCCESS").tap { |r| r["amount"]["payer_refund"] = 500 } }
    assert_equal "SUCCESS", @payments.query_refund(PAYMENT, refund_no: REFUND)[:state]
    assert_equal 500, @order.refunded_cash
    assert_equal [ [ original_merchant, current.serial.to_s(16).upcase ] ], seen.drop(1).uniq
    assert_equal 1, @order.credits
  end

  test "v3 request identifies the primary WeChat verifier and separately signs with the merchant serial" do
    @key_id = "PUB_KEY_ID_0115635139512024101100397200000006"
    prepare("v3")
    pub_key = @wechat_key
    platform_key = OpenSSL::PKey::RSA.generate(2048)
    platform = payment_certificate(platform_key, "Platform rotation test")
    pub_id = expected_id = @key_id
    path = "/v3/pay/transactions/out-trade-no/#{PAYMENT}?mchid=#{@merchant_id}"
    @stubs.get(path) do |req|
      assert_equal expected_id, req.request_headers.fetch("Wechatpay-Serial")
      assert_includes req.request_headers.fetch("Authorization"), %(serial_no="#{@certificate.serial.to_s(16).upcase}")
      raw = JSON.generate(payment_data("v3", "NOTPAY"))
      [ 200, v3_headers(raw), raw ]
    end
    assert_equal "NOTPAY", @payments.query(PAYMENT)[:state]
    expected_id = @key_id = platform.serial.to_s(16).upcase
    @wechat_key = platform_key
    update_payment_settings("verification_id" => @key_id, "verification_pem" => platform.to_pem,
      "backup_verification_id" => pub_id, "backup_verification_pem" => pub_key.public_key.to_pem)
    assert_equal "NOTPAY", @payments.query(PAYMENT)[:state]
    travel_to(platform.not_after + 1.day) do
      expected_id = @key_id = pub_id
      @wechat_key = pub_key
      assert_equal "NOTPAY", @payments.query(PAYMENT)[:state]
    end
  end

  test "historical inactive merchant with no registry selects its own newest legacy archive" do
    prepare("v3")
    original = @merchant_id
    old_ref = @payment.fetch("config_ref")
    @merchant_key = OpenSSL::PKey::RSA.generate(2048)
    @certificate = payment_certificate(@merchant_key, original)
    configure("v3")
    expected = @certificate.serial.to_s(16).upcase
    @merchant_id = "1900000002"
    update_payment_settings(payment_settings("v2").except(*WechatPaySettings::V2_TLS))
    Setting.where("key LIKE 'wechat_pay_current:%'").delete_all
    assert_equal [ original, "v3", expected ], WechatPaySettings.fetch!(old_ref).values_at("merchant_id", "version", "merchant_serial")
  end

  test "v3 verifies alternating platform certificate and public key, rejects expired unknown and removed signers" do
    prepare("v3")
    pub_id, pub_key = @key_id, @wechat_key
    platform_key = OpenSSL::PKey::RSA.generate(2048)
    platform = payment_certificate(platform_key, "Test Platform")
    platform_id = platform.serial.to_s(16).upcase
    update_payment_settings("backup_verification_id" => platform_id, "backup_verification_pem" => platform.to_pem)
    set_signer = ->(id, key) { @key_id, @wechat_key = id, key }
    [ [ platform_id, platform_key ], [ pub_id, pub_key ], [ platform_id, platform_key ] ].each do |id, key|
      set_signer.call(id, key)
      notify("v3", "payment", payment_data("v3"))
      assert_response :no_content
    end
    travel_to(platform.not_after + 1.second) do
      notify("v3", "payment", payment_data("v3"))
      assert_response :bad_request
      set_signer.call(pub_id, pub_key)
      notify("v3", "payment", payment_data("v3"))
      assert_response :no_content
    end
    update_payment_settings("remove_backup" => "1")
    [ platform_id, "PUB_KEY_ID_100" ].each do |id|
      set_signer.call(id, platform_key)
      notify("v3", "payment", payment_data("v3"))
      assert_response :bad_request
    end
    set_signer.call(pub_id, pub_key)
    notify("v3", "payment", payment_data("v3"))
    assert_response :no_content
    assert_equal 1, @order.credits
  end
end

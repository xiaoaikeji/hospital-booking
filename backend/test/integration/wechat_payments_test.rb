require "test_helper"
require_relative "../support/wechat_http_test"
require_relative "../support/wechat_pay_protocol"

class WechatPaymentsTest < ActionDispatch::IntegrationTest
  include WechatHttpTest
  include WechatPayProtocol

  PAYMENT = "20261123090000123456"
  REFUND = "20261123100000654321"
  TRANSACTION_ID = "420000000000000000001"
  REFUND_ID = "500000000000000000001"

  class BusinessOrder
    attr_reader :payment_context, :refunds, :credits, :refunded
    attr_accessor :write_failure

    def initialize(context)
      @payment_context, @refunds = context, {}
      @credits = @refunded = 0
      @lock = Mutex.new
    end

    def with_payment(number)
      return unless number == payment_context["payment_no"]
      @lock.synchronize { yield self }
    end

    def refund(number) = refunds[number]

    def save_checkout!(attributes)
      payment_context.merge!(attributes)
      true
    end

    def mark_refund_attempted!(number)
      refunds.fetch(number)["attempted"] = true
    end

    def reserve(number, cents)
      @lock.synchronize do
        existing = refunds[number]
        return existing if existing && existing["refund_cents"] == cents
        raise "refund number reused" if existing
        reserved = refunds.values.reject { |row| row["state"] == "CLOSED" }.sum { |row| row.fetch("refund_cents") }
        raise "over reservation" unless cents.is_a?(Integer) && cents.positive? && reserved + cents <= payment_context.fetch("amount_cents")
        refunds[number] = { "refund_no" => number, "refund_cents" => cents, "state" => "PROCESSING" }
      end
    end

    def refunded_cash
      amounts = refunds.values.select { |record| record["state"] == "SUCCESS" }.pluck("payer_refund_cents")
      amounts.sum unless amounts.include?(nil)
    end

    def apply!(result)
      raise ActiveRecord::StatementInvalid if write_failure == :raise
      return false if write_failure == :decline
      case result.values_at(:kind, :state)
      when [ :payment, "SUCCESS" ]
        unless payment_context["transaction_id"]
          @credits += 1
          payment_context.merge!("transaction_id" => result[:transaction_id], "paid_cents" => result[:paid_cents])
        end
      when [ :payment, "CLOSED" ]
        payment_context["closed"] = true unless payment_context["transaction_id"]
      end
      if result[:kind] == :refund
        record = refunds.fetch(result[:refund_no])
        state = result[:state]
        return true if record["state"] == "SUCCESS" && state != "SUCCESS"
        raise Payments::InvalidResult if record["state"] == "CLOSED" && state == "SUCCESS"
        return true if record["state"] == "CLOSED" && state != "CLOSED"
        return true if record["state"] == "ABNORMAL" && state == "PROCESSING"
        cash = result[:payer_refund_cents]
        if state == "SUCCESS"
          confirmed = refunds.except(result[:refund_no]).values.select { |r| r["state"] == "SUCCESS" }.sum { |r| r["payer_refund_cents"] || 0 }
          raise Payments::InvalidResult if cash && confirmed + cash > payment_context.fetch("paid_cents")
          @refunded += result[:refund_cents] unless record["state"] == "SUCCESS"
        end
        record.merge!("refund_id" => result[:refund_id], "state" => state)
        record["payer_refund_cents"] = cash unless cash.nil?
        record["acceptance_state"] = result[:acceptance_state] if result[:acceptance_state]
      end
      true
    end
  end

  setup do
    install_wechat_stubs
    generate_payment_keys
    @mini_program = App.create!(appid: "wx_clinic_a", provider: "wechat", status: "active")
    @identity = UserApp.create!(app: @mini_program, user: User.create!(platform: "wechat"), openid: "test-payer-A", last_sign_in_at: Time.current)
    @previous = Rails.application.config.x.payments.receiver
  end

  teardown do
    Rails.application.config.x.payments.receiver = @previous
    remove_wechat_stubs
  end

  def configure(version)
    settings = WechatPaySettings.new
    assert settings.save(payment_settings(version).merge("revision" => settings.revision), actor: nil), settings.errors.full_messages
  end

  def prepare(version)
    configure(version)
    @payment = Payments.new.prepare(app: @mini_program, identity: @identity, payment_no: PAYMENT, amount_cents: 2000)
    @order = BusinessOrder.new(@payment)
    Rails.application.config.x.payments.receiver = @order
    @payments = Payments.new
  end

  def checkout(app: @mini_program, identity: @identity)
    @payments.checkout(PAYMENT, app: app, identity: identity, client_ip: "127.0.0.1", description: "支付底座测试")
  end

  def payment_data(version, state = "SUCCESS")
    if version == "v2"
      fields = { "trade_state" => state, "out_trade_no" => PAYMENT }
      return fields unless state == "SUCCESS"
      fields.merge("trade_type" => "JSAPI", "total_fee" => "2000", "cash_fee" => "2000", "openid" => @identity.openid,
        "transaction_id" => TRANSACTION_ID, "time_end" => "20261123093045")
    else
      fields = { "mchid" => @merchant_id, "appid" => @mini_program.appid, "out_trade_no" => PAYMENT, "trade_state" => state }
      return fields unless state == "SUCCESS"
      fields.merge("amount" => { "total" => 2000, "payer_total" => 2000, "currency" => "CNY", "payer_currency" => "CNY" },
        "trade_type" => "JSAPI", "payer" => { "openid" => @identity.openid }, "transaction_id" => TRANSACTION_ID,
        "success_time" => "2026-11-23T09:30:45+08:00")
    end
  end

  def refund_data(version, cents, state, query: false)
    identity = { "transaction_id" => TRANSACTION_ID, "out_trade_no" => PAYMENT, "out_refund_no" => REFUND, "refund_id" => REFUND_ID }
    if version == "v2"
      item = identity.slice("out_refund_no", "refund_id").merge("refund_status" => state, "refund_fee" => cents.to_s)
      if query
        # A different first item makes using refund_fee_0 or the aggregate unsafe.
        item = item.transform_keys { |key| "#{key}_1" }.merge("refund_count" => "2", "out_refund_no_0" => "20261120100000111111",
          "refund_fee_0" => "1", "refund_fee" => (cents + 1).to_s)
      end
      identity.slice("transaction_id", "out_trade_no").merge("total_fee" => "2000").merge(item)
    else
      identity.merge("status" => state, "amount" => { "total" => 2000, "refund" => cents, "currency" => "CNY" })
    end
  end

  def stub_payment_query(version, &data)
    if version == "v2"
      stub_wechat(version, :post, "/pay/orderquery") do |fields|
        assert_equal PAYMENT, fields["out_trade_no"]
        data.call
      end
    else
      stub_wechat(version, :get, "/v3/pay/transactions/out-trade-no/#{PAYMENT}?mchid=#{@merchant_id}") { data.call }
    end
  end

  def stub_refund_query(version, &data)
    if version == "v2"
      stub_wechat(version, :post, "/pay/refundquery") do |fields|
        assert_equal REFUND, fields.fetch("out_refund_no")
        data.call
      end
    else
      stub_wechat(version, :get, "/v3/refund/domestic/refunds/#{REFUND}") { data.call }
    end
  end

  def notify(version, kind, data, &alter)
    body, headers = notification_packet(version, kind, data)
    body, headers = alter.call(body, headers) if alter
    post api_wechat_payment_notification_path(version: version, config_ref: @payment.fetch("config_ref"), kind: kind),
      params: body, headers: headers
  end

  %w[v2 v3].each do |version|
    test "#{version} rejects a signed query for another order or amount" do
      prepare(version)
      data = payment_data(version)
      stub_payment_query(version) { data }
      data["out_trade_no"] = REFUND
      assert_raises(Payments::InvalidResult) { @payments.query(PAYMENT) }
      data["out_trade_no"] = PAYMENT
      if version == "v2"
        data["total_fee"] = "1999"
      else
        data["amount"]["total"] = 2000.0
      end
      assert_raises(Payments::InvalidResult) { @payments.query(PAYMENT) }
      assert_equal 0, @order.credits
    end

    test "#{version} prepay, resume, app isolation and authoritative close" do
      prepare(version)
      v2 = version == "v2"
      submitted = 0
      stub_wechat(version, :post, v2 ? "/pay/unifiedorder" : "/v3/pay/transactions/jsapi") do |request|
        submitted += 1
        assert_equal PAYMENT, request["out_trade_no"]
        assert_equal @identity.openid, v2 ? request["openid"] : request.dig("payer", "openid")
        assert_equal @mini_program.appid, request["appid"]
        assert_equal 2000, v2 ? Integer(request.fetch("total_fee"), 10) : request.dig("amount", "total")
        assert_equal "https://booking.example.org/api/wechat/pay/#{version}/#{@payment.fetch("config_ref")}/payment", request["notify_url"]
        { "trade_type" => "JSAPI", "prepay_id" => "wx_test_prepay" }
      end
      first = checkout
      @payment.merge!(first.except("payment_params"))
      second = checkout
      assert_equal 1, submitted
      refute_equal first["payment_params"], second["payment_params"]
      signed = second.fetch("payment_params")
      assert_equal "prepay_id=wx_test_prepay", signed.fetch("package")
      if v2
        assert_equal "HMAC-SHA256", signed["signType"]
        assert_equal v2_signature(signed.except("paySign").merge("appId" => @mini_program.appid)), signed["paySign"]
      else
        message = [ @mini_program.appid, *signed.values_at("timeStamp", "nonceStr", "package"), "" ].join("\n")
        assert @merchant_key.public_key.verify("SHA256", Base64.strict_decode64(signed.fetch("paySign")), message)
      end
      other = App.create!(appid: "wx_clinic_b", provider: "wechat", status: "active")
      assert_raises(Payments::Error) { checkout(app: other) }
      assert_raises(Payments::Error) { @payments.prepare(app: other, identity: @identity, payment_no: PAYMENT, amount_cents: 1) }
      other_identity = UserApp.create!(app: other, user: @identity.user, openid: "test-payer-B", last_sign_in_at: Time.current)
      assert_raises(Payments::Error) { checkout(app: other, identity: other_identity) }
      state = "NOTPAY"
      stub_payment_query(version) { payment_data(version, state) }
      stub_wechat(version, :post, v2 ? "/pay/closeorder" : "/v3/pay/transactions/out-trade-no/#{PAYMENT}/close", status: v2 ? 200 : 204) do |request|
        assert_equal PAYMENT, request["out_trade_no"] if v2
        state = "CLOSED"
        {}
      end
      assert_equal "CLOSED", @payments.close(PAYMENT)[:state]
      assert_raises(Payments::Error) { checkout }
      assert_equal 0, @order.credits
    end

    test "#{version} concurrent query and repeated payment notifications settle once after the cashier is gone" do
      prepare(version)
      @payment["paid_cents"] = 0
      data = payment_data(version)
      stub_payment_query(version) { data }
      body, headers = notification_packet(version, "payment", version == "v2" ? data.except("trade_state") : data)
      ready, start = Queue.new, Queue.new
      threads = 3.times.map do |index|
        Thread.new do
          ready << true
          start.pop
          index.zero? ? @payments.query(PAYMENT) : @payments.receive(version: version, config_ref: @payment.fetch("config_ref"),
            kind: "payment", body: body, headers: headers)
        end
      end
      3.times { ready.pop }
      3.times { start << true }
      assert_equal [ "SUCCESS" ], threads.map(&:value).pluck(:state).uniq
      assert_equal 1, @order.credits
      assert_equal 2000, @payment.fetch("paid_cents")
    end

    test "#{version} callbacks reject unsigned, mismatched, missing and unwritten orders" do
      prepare(version)
      data = payment_data(version)
      notify(version, "payment", data) do |body, headers|
        if version == "v2"
          [ body.sub("<sign>", "<sign>0"), headers ]
        else
          [ body, headers.merge("Wechatpay-Signature" => "invalid") ]
        end
      end
      assert_response :bad_request
      bad = version == "v2" ? { "mch_id" => "42", "total_fee" => "1999", "appid" => "wx_other", "openid" => "other" } :
        { "mchid" => "42", "appid" => "wx_other", "amount" => data["amount"].merge("total" => 1999), "payer" => { "openid" => "other" } }
      bad.each do |key, value|
        notify(version, "payment", data.merge(key => value))
        assert_response :bad_request
      end
      notify(version, "payment", data.merge("out_trade_no" => REFUND))
      assert_response :service_unavailable
      [ :raise, :decline ].each do |failure|
        @order.write_failure = failure
        notify(version, "payment", data)
        assert_response :service_unavailable
        assert_match(/FAIL/, response.body)
      end
      assert_equal 0, @order.credits
      @order.write_failure = nil
      notify(version, "payment", data)
      assert_response(version == "v2" ? :ok : :no_content)
      assert_match(/SUCCESS/, response.body) if version == "v2"
      notify(version, "payment", data.merge("transaction_id" => "111111"))
      assert_response :bad_request
      assert_equal 1, @order.credits
    end

    test "#{version} a refund timeout followed by not found keeps the original reservation" do
      prepare(version)
      notify(version, "payment", payment_data(version))
      @order.reserve(REFUND, 500)
      v2 = version == "v2"
      stub_wechat(version, :post, v2 ? "/secapi/pay/refund" : "/v3/refund/domestic/refunds") { raise Faraday::TimeoutError }
      if v2
        stub_refund_query(version) { { "result_code" => "FAIL", "err_code" => "REFUNDNOTEXIST" } }
      else
        stub_wechat(version, :get, "/v3/refund/domestic/refunds/#{REFUND}", status: 404) { { "code" => "RESOURCE_NOT_EXISTS" } }
      end
      assert_raises(Payments::Unavailable) { @payments.refund(PAYMENT, refund_no: REFUND) }
      assert_equal({ "refund_no" => REFUND, "refund_cents" => 500, "state" => "PROCESSING", "attempted" => true }, @order.refund(REFUND))
      assert_equal 0, @order.refunded
    end

    [ 500, 2000 ].each do |cents|
      test "#{version} #{cents} cent refund uses the original profile and number through acceptance, query and replay" do
        prepare(version)
        configure(version == "v2" ? "v3" : "v2")
        stub_payment_query(version) { payment_data(version) }
        @payments.query(PAYMENT)
        notify(version, "payment", payment_data(version))
        assert_response(version == "v2" ? :ok : :no_content)
        assert_equal 1, @order.credits
        @order.reserve(REFUND, cents)
        assert_raises(RuntimeError) { @order.reserve("20261123100000222222", 2001 - cents) }
        v2 = version == "v2"
        count, queries = 0, 0
        state = "PROCESSING"
        stub_refund_query(version) do
          queries += 1
          refund_data(version, cents, state, query: true)
        end
        stub_wechat(version, :post, v2 ? "/secapi/pay/refund" : "/v3/refund/domestic/refunds") do |request|
          count += 1
          assert_equal [ PAYMENT, REFUND ], request.values_at("out_trade_no", "out_refund_no")
          assert_equal cents, v2 ? Integer(request["refund_fee"], 10) : request.dig("amount", "refund")
          assert_equal "https://booking.example.org/api/wechat/pay/#{version}/#{@payment.fetch("config_ref")}/refund", request["notify_url"]
          raise Faraday::TimeoutError if cents == 500
          refund_data(version, cents, state)
        end
        assert_equal "PROCESSING", @payments.refund(PAYMENT, refund_no: REFUND)[:state]
        assert_equal(cents == 500 ? 1 : 0, queries)
        assert_equal 0, @order.refunded
        state = "SUCCESS"
        assert_equal state, @payments.query_refund(PAYMENT, refund_no: REFUND)[:state]
        data = refund_data(version, cents, state)
        unless v2
          data["mchid"] = @merchant_id
          data["refund_status"] = data.delete("status")
          data["amount"].delete("currency")
        end
        notify(version, "refund", data)
        assert_response(v2 ? :ok : :no_content)
        assert_equal cents, @order.refunded
        assert_equal 1, count
        assert_equal REFUND_ID, @order.refund(REFUND).fetch("refund_id")
      end
    end
  end

  test "v2 refund ciphertext cannot settle without matching independent signed query and business commit" do
    prepare("v2")
    settings = WechatPaySettings.new
    new_key = SecureRandom.hex(16)
    assert settings.save({ "revision" => settings.revision, "v2_api_key" => new_key }, actor: nil)
    refute_equal @payment["config_ref"], WechatPaySettings.new.reserve!.fetch("config_ref")
    notify("v2", "payment", payment_data("v2"))
    assert_response :bad_request
    @v2_key = new_key
    notify("v2", "payment", payment_data("v2"))
    assert_response :ok
    data = refund_data("v2", 500, "SUCCESS")
    notify("v2", "refund", data)
    assert_response :service_unavailable
    @order.reserve(REFUND, 500)
    state = "PROCESSING"
    stub_refund_query("v2") { refund_data("v2", 500, state, query: true) }
    notify("v2", "refund", data)
    assert_response :bad_request
    state = "SUCCESS"
    @order.write_failure = :raise
    notify("v2", "refund", data)
    assert_response :service_unavailable
    assert_equal 0, @order.refunded
    @order.write_failure = nil
    notify("v2", "refund", data)
    assert_response :ok
    assert_equal 500, @order.refunded
  end

  test "v3 verifies the signer, timestamp, raw body and authenticated ciphertext before delivery" do
    prepare("v3")
    data = payment_data("v3")
    changes = [
      ->(body, h) { [ body, h.merge("Wechatpay-Serial" => "PUB_KEY_ID_0") ] },
      ->(body, h) { [ body, h.merge(v3_headers(body, timestamp: 6.minutes.ago.to_i.to_s)) ] },
      ->(body, h) { [ body + " ", h ] },
      ->(body, h) do
        envelope = JSON.parse(body)
        envelope["resource"]["associated_data"] = "other"
        altered = JSON.generate(envelope)
        [ altered, h.merge(v3_headers(altered)) ]
      end
    ]
    changes.each do |change|
      notify("v3", "payment", data, &change)
      assert_response :bad_request
    end
    body = JSON.generate(data)
    @stubs.get("/v3/pay/transactions/out-trade-no/#{PAYMENT}?mchid=#{@merchant_id}") do
      [ 200, v3_headers(body + " "), body ]
    end
    assert_raises(Payments::InvalidResult) { @payments.query(PAYMENT) }
    assert_equal 0, @order.credits
  end
end

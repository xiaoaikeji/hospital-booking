require_relative "wechat_payments_test"

class WechatPaymentsTest
  test "independent v2 collection only configuration works without the optional refund certificate" do
    settings = WechatPaySettings.new
    fields = payment_settings("v2").except("v2_certificate", "v2_private_key")
    saved = settings.save(fields.merge("revision" => settings.revision), actor: nil)
    assert saved, settings.errors.full_messages.join(", ")
    context = Payments.new.prepare(app: @mini_program, identity: @identity, payment_no: PAYMENT, amount_cents: 2000)
    @order = BusinessOrder.new(context)
    @payments = Payments.new(receiver: @order)
    stub_wechat("v2", :post, "/pay/unifiedorder") { { "trade_type" => "JSAPI", "prepay_id" => "test-prepay" } }
    assert_equal "HMAC-SHA256", checkout.fetch("payment_params").fetch("signType")
  end

  test "independent v3 same merchant can query an existing order with its replaced certificate" do
    prepare("v3")
    previous_serial = @certificate.serial.to_s(16).upcase
    @merchant_key = OpenSSL::PKey::RSA.generate(2048)
    @certificate = payment_certificate(@merchant_key, @merchant_id)
    current_serial = @certificate.serial.to_s(16).upcase
    configure("v3")
    fresh_number = PAYMENT.succ
    fresh_context = @payments.prepare(app: @mini_program, identity: @identity, payment_no: fresh_number, amount_cents: 2000)
    fresh_order = BusinessOrder.new(fresh_context)

    seen = {}
    [ PAYMENT, fresh_number ].each do |number|
      @stubs.get("/v3/pay/transactions/out-trade-no/#{number}?mchid=#{@merchant_id}") do |request|
        serial = request.request_headers.fetch("Authorization")[/serial_no="([^"]+)"/, 1]
        seen[number] = serial
        accepted = serial == current_serial
        data = accepted ? payment_data("v3").merge("out_trade_no" => number) : { "code" => "SIGN_ERROR" }
        raw = JSON.generate(data)
        [ accepted ? 200 : 401, v3_headers(raw), raw ]
      end
    end
    assert_equal "SUCCESS", Payments.new(receiver: fresh_order).query(fresh_number)[:state]
    refute_equal previous_serial, current_serial
    outcome = begin
      @payments.query(PAYMENT)[:state]
    rescue Payments::Error => error
      error.class.name
    end
    assert_equal "SUCCESS", outcome, "new order accepted; old order used revoked serial: #{seen[PAYMENT] == previous_serial}"
  end

  test "independent v3 inconclusive plain gateway error triggers signed refund lookup on the original number" do
    prepare("v3")
    notify("v3", "payment", payment_data("v3"))
    assert_response :no_content
    @order.reserve(REFUND, 500)
    applications = 0
    queries = 0
    @stubs.post("/v3/refund/domestic/refunds") do
      applications += 1
      [ 503, { "Content-Type" => "text/plain" }, "Service Unavailable" ]
    end
    stub_refund_query("v3") do
      queries += 1
      refund_data("v3", 500, "SUCCESS", query: true)
    end
    outcome = begin
      @payments.refund(PAYMENT, refund_no: REFUND)[:state]
    rescue Payments::Error => error
      error.class.name
    end
    assert_equal [ 1, 1, "SUCCESS", 500 ], [ applications, queries, outcome, @order.refunded ]
  end

  test "independent legitimate discounted transaction can request a full channel refund" do
    prepare("v3")
    data = payment_data("v3")
    data["amount"]["payer_total"] = 1600
    notify("v3", "payment", data)
    assert_response :no_content
    assert_equal 1600, @order.payment_context["paid_cents"]
    # Reserve the face amount directly in the test receiver to exercise the channel independently.
    @order.refunds[REFUND] = { "refund_no" => REFUND, "refund_cents" => 2000, "state" => "PROCESSING" }
    submissions = 0
    stub_wechat("v3", :post, "/v3/refund/domestic/refunds") do
      submissions += 1
      payload = refund_data("v3", 2000, "PROCESSING")
      payload["amount"].merge!("payer_total" => 1600, "payer_refund" => 1600, "discount_refund" => 400)
      payload
    end
    outcome = begin
      @payments.refund(PAYMENT, refund_no: REFUND)[:state]
    rescue Payments::Error => error
      error.class.name
    end
    assert_equal [ 1, "PROCESSING" ], [ submissions, outcome ]
  end
end

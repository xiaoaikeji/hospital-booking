require_relative "wechat_payments_test"

class WechatPaymentsTest
  def pay_with_cash(version, cash)
    prepare(version)
    data = payment_data(version)
    version == "v2" ? data["cash_fee"] = cash.to_s : data.fetch("amount")["payer_total"] = cash
    notify(version, "payment", data)
    assert_response(version == "v2" ? :ok : :no_content)
    assert_equal cash, @payment.fetch("paid_cents")
  end

  %w[v2 v3].each do |version|
    { full: [ 1600, [ [ 2000, 1600 ] ] ], partial: [ 1600, [ [ 1000, 800 ] ] ], above_cash: [ 1600, [ [ 1800, 1440 ] ] ],
      split: [ 1600, [ [ 1000, 800 ], [ 1000, 800 ] ] ], uneven: [ 1600, [ [ 1000, 743 ], [ 1000, 857 ] ] ],
      coupon_only: [ 0, [ [ 2000, 0 ] ] ], no_coupon: [ 2000, [ [ 2000, 2000 ] ] ] }.each do |name, (paid, items)|
      test "#{version} settles #{name} using the channel's exact cash and the reserved face amount" do
        pay_with_cash(version, paid)
        v2 = version == "v2"
        applications, lookups = [], []
        items.each_with_index do |(gross, cash), i|
          number = (REFUND.to_i + i).to_s
          refund_id = (REFUND_ID.to_i + i).to_s
          @order.reserve(number, gross)
          stub_wechat(version, :post, v2 ? "/secapi/pay/refund" : "/v3/refund/domestic/refunds") do |req|
            applications << [ req.fetch("out_refund_no"), v2 ? Integer(req["refund_fee"]) : req.dig("amount", "refund") ]
            assert_equal 2000, v2 ? Integer(req["total_fee"]) : req.dig("amount", "total")
            refund_data(version, gross, "PROCESSING").merge("out_refund_no" => number, "refund_id" => refund_id)
          end
          assert_equal "PROCESSING", @payments.refund(PAYMENT, refund_no: number)[:state]
          assert_equal items.take(i).sum(&:last), @order.refunded_cash
          stub_wechat(version, v2 ? :post : :get, v2 ? "/pay/refundquery" : "/v3/refund/domestic/refunds/#{number}") do |req|
            lookups << (v2 ? req.fetch("out_refund_no") : number)
            data = refund_data(version, gross, "SUCCESS", query: true)
            if v2
              data.merge!("out_refund_no_1" => number, "refund_id_1" => refund_id, "cash_fee" => paid.to_s,
                "cash_refund_fee_1" => cash.to_s, "coupon_refund_fee_1" => (gross - cash).to_s)
            else
              data.merge!("out_refund_no" => number, "refund_id" => refund_id)
              data.fetch("amount").merge!("payer_total" => paid, "payer_refund" => cash)
            end
            data
          end
          confirmed = @payments.query_refund(PAYMENT, refund_no: number)
          assert_equal [ "SUCCESS", gross, cash ], confirmed.values_at(:state, :refund_cents, :payer_refund_cents)
        end
        assert_equal items.map.with_index { |(gross, _), i| [ (REFUND.to_i + i).to_s, gross ] }, applications
        assert_equal applications.map(&:first), lookups
        assert_equal [ items.sum(&:first), items.sum(&:last) ], [ @order.refunded, @order.refunded_cash ]
      end
    end
  end

  test "v2 sparse query and encrypted notice preserve trusted cash without inventing an amount" do
    pay_with_cash("v2", 1600)
    @order.reserve(REFUND, 1000)
    data = refund_data("v2", 1000, "SUCCESS", query: true).merge("settlement_refund_fee_1" => "920", "coupon_refund_fee" => "291")
    stub_refund_query("v2") { data }
    notice = refund_data("v2", 1000, "SUCCESS").merge("cash_refund_fee" => "743")
    assert_equal "SUCCESS", @payments.query_refund(PAYMENT, refund_no: REFUND)[:state]
    assert_nil @order.refunded_cash
    assert_equal 1000, @order.refunded
    notify("v2", "refund", notice)
    assert_response :ok
    assert_equal 743, @order.refunded_cash
    assert_equal 743, @payments.query_refund(PAYMENT, refund_no: REFUND)[:payer_refund_cents]
    data["coupon_refund_fee_1"] = "257"
    notify("v2", "refund", notice.merge("cash_refund_fee" => "744"))
    assert_response :bad_request
    assert_equal [ 1000, 743 ], [ @order.refunded, @order.refunded_cash ]
  end

  test "concurrent reservations cap the face value and signed results cap the total cash" do
    pay_with_cash("v3", 1600)
    ready, start = Queue.new, Queue.new
    attempts = [ REFUND, REFUND.succ, REFUND.succ.succ ].map do |number|
      Thread.new do
        ready << true
        start.pop
        @order.reserve(number, 1000)
        true
      rescue RuntimeError => error
        raise unless error.message == "over reservation"
        false
      end
    end
    3.times { ready.pop }
    3.times { start << true }
    assert_equal 2, attempts.count(&:value)
    assert_equal 2000, @order.refunds.values.sum { |r| r.fetch("refund_cents") }
    @order.refunds.keys.each_with_index do |number, i|
      data = refund_data("v3", 1000, "SUCCESS").merge("out_refund_no" => number, "refund_id" => (REFUND_ID.to_i + i).to_s)
      data["amount"].merge!("payer_refund" => 900, "payer_total" => 1600)
      stub_wechat("v3", :get, "/v3/refund/domestic/refunds/#{number}") { data }
      if i.zero?
        @payments.query_refund(PAYMENT, refund_no: number)
      else
        assert_raises(Payments::InvalidResult) { @payments.query_refund(PAYMENT, refund_no: number) }
        assert_equal "PROCESSING", @order.refund(number)["state"]
        data["amount"]["payer_refund"] = 700
        @payments.query_refund(PAYMENT, refund_no: number)
      end
    end
    assert_equal [ 2000, 1600 ], [ @order.refunded, @order.refunded_cash ]
  end
end

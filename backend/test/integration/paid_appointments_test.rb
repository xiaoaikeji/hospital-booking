require "test_helper"
require_relative "../support/wechat_http_test"
require_relative "../support/wechat_pay_protocol"

class PaidAppointmentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  include WechatPayProtocol

  setup do
    @started_at = Time.zone.local(2026, 11, 27, 9, 25)
    travel_to @started_at
    install_wechat_stubs
    generate_payment_keys
    @mini_program = App.create!(provider: "wechat", status: "active", appid: "fixture_paid_appointments")
    @user = User.create!(platform: "wechat")
    @identity = @user.user_apps.create!(app: @mini_program, openid: "fixture-patient", last_sign_in_at: Time.current)
    @headers = { "Authorization" => "Bearer #{MiniProgramSession.issue!(@identity).fetch(:token)}" }
    @department = Department.create!(name: "虚构收费门诊")
    @doctor = Doctor.create!(name: "虚构收费医生", departments: [ @department ], fee: 20)
    @doctor.schedules.create!(time_slot: "AM", weekday: Date.current.wday, start_date: Date.current, capacity: 1)
    @settings = Setting.find_or_create_by!(key: "appointment")
    @settings.update!(settings: { "booking_by_time_slot" => true, "max_bookings_per_slot" => 1 })
    @operator = Admin.create!(username: "fixture_operator", role: "operator")
    @version = "v3"
    config = WechatPaySettings.new
    assert config.save(payment_settings(@version).merge("revision" => config.revision), actor: nil)
  end

  teardown { remove_wechat_stubs }

  def run
    Sidekiq.testing!(:fake) { super }
  end

  test "resume after the slot starts and expire from the first creation without freeing early" do
    draft = booking_draft
    order = book!(draft)
    assert_equal @started_at + 30.minutes, order.payment_expires_at
    assert_equal 0, remaining(order)
    assert_equal 0, order.paid_amount_cents
    @doctor.update!(fee: 15)

    calls = stub_checkout(order)
    first = post_checkout(order)
    travel_to @started_at + 10.minutes
    post_booking(draft.merge(idempotency_key: SecureRandom.uuid))
    assert_response :unprocessable_content
    assert_equal "slot_closed", response.parsed_body.fetch("code")
    post_booking(draft)
    assert_response :ok
    assert_equal [ order.order_no, "replayed" ], response.parsed_body.values_at("order_no", "outcome")
    assert_equal first["package"], post_checkout(order)["package"]
    assert_equal [ 2000 ], calls
    assert_equal @started_at + 30.minutes, order.reload.payment_expires_at

    state = "NOTPAY"
    stub_query(order) { payment_result(order, state) }
    stub_wechat("v3", :post, "#{trade_path(order)}/close", status: 204) do
      state = "USERPAYING"
      {}
    end
    travel_to @started_at + 30.minutes
    post "#{patient_path(order)}/payment", headers: @headers, as: :json
    assert_response :unprocessable_content
    Appointments::ReconcileWorker.new.perform(order.id)
    assert_equal [ "pending_payment", 0 ], [ order.reload.status, remaining(order) ]
    state = "CLOSED"
    Appointments::ReconcileWorker.new.perform(order.id)
    assert_equal [ "cancelled", "closed", 0, 1 ], [ order.reload.status, order.payment_status, order.paid_amount_cents, remaining(order) ]
    post_booking(draft.merge(idempotency_key: SecureRandom.uuid))
    assert_equal "slot_closed", response.parsed_body.fetch("code")
  end

  test "a signed payment delivered while staff is closing keeps the booking and offers a hospital return" do
    order = book!
    stub_checkout(order)
    post_checkout(order)
    state = "NOTPAY"
    stub_query(order) { payment_result(order, state) }
    stub_wechat("v3", :post, "#{trade_path(order)}/close", status: 400) do
      state = "SUCCESS"
      send_notification(order, "payment", payment_result(order), open_session)
      { "code" => "ORDER_PAID" }
    end
    sign_in @operator
    cancel_as_staff(order)
    follow_redirect!
    assert_includes response.body, "微信已确认收款"
    assert_select "button", text: "医院退号", count: 1
    assert_select "button", text: "取消待支付预约", count: 0
    assert_equal [ "confirmed", "paid", 2000, 0 ], [ order.reload.status, order.payment_status, order.paid_amount_cents, remaining(order) ]
    send_notification(order, "payment", payment_result(order))
    assert_equal 1, order_logs(order, "payment_confirmed").count
  end

  test "no prepay was ever sent for an expired untouched appointment" do
    order = book!
    travel_to @started_at + 30.minutes
    Appointments::ReconcileWorker.new.perform(order.id)
    assert_equal [ "cancelled", "closed", 1 ], [ order.reload.status, order.payment_status, remaining(order) ]
    @stubs.verify_stubbed_calls
  end

  test "staff close an untouched suspended booking while customer service can only read it" do
    order = book!
    suspend_schedule(order)
    sign_in Admin.create!(username: "fixture_support", role: "customer_service")
    get admins_reservation_path(order.order_no)
    assert_select "button", text: "取消待支付预约", count: 0
    cancel_as_staff(order, expected: :forbidden)
    assert order.reload.pending_payment?

    admin = Admin.create!(username: "fixture_super_admin", role: "super_admin")
    sign_in admin
    get admins_reservation_path(order.order_no)
    assert_select "button", text: "取消待支付预约", count: 1
    cancel_as_staff(order, reason: " ")
    follow_redirect!
    assert_includes response.body, "请填写取消原因"
    assert_nil order.reload.payment_cancel_requested_at

    2.times { cancel_as_staff(order) }
    follow_redirect!
    assert_includes response.body, "待支付预约已取消"
    assert_includes response.body, "虚构医生停诊"
    assert_includes response.body, admin.username
    assert_equal [ "cancelled", "closed" ], order.reload.attributes.values_at("status", "payment_status")
    audit = Log.operations_visible_to(admin).merge(order_logs(order, "payment_close_requested")).sole
    assert_equal [ "Admin", admin.id ], audit.attributes.values_at("actor_type", "actor_id")
    get admins_operation_log_path(audit)
    assert_includes response.body, order.order_no
    refute_includes response.body, "虚构医生停诊"
    closed = order_logs(order, "payment_closed").sole
    assert_equal "NOT_CREATED", closed.details.fetch("channel_outcome")
    get admins_operation_log_path(closed)
    assert_includes response.body, "本地关单"
    refute Appointment.occupying.exists?(order.id)
    assert_empty ScheduleCalendar.new([ @doctor.id ], order.appointment_date..order.appointment_date).day_availability(@doctor.id, order.appointment_date)[:shifts]
    post "#{patient_path(order)}/payment", headers: @headers, as: :json
    assert_response :unprocessable_content
  end

  test "staff cancellation blocks checkout immediately and holds the seat until WeChat closes the order" do
    order = book!
    stub_checkout(order)
    post_checkout(order)
    state = "NOTPAY"
    stub_query(order) { payment_result(order, state) }
    stub_wechat("v3", :post, "#{trade_path(order)}/close", status: 204) do
      patient = open_session
      patient.post "#{patient_path(order)}/payment", headers: @headers, as: :json
      assert_equal 422, patient.response.status
      state = "USERPAYING"
      {}
    end
    sign_in @operator
    cancel_as_staff(order)
    follow_redirect!
    assert_includes response.body, "关单核实中"
    assert_equal [ "pending_payment", 0 ], [ order.reload.status, remaining(order) ]

    state = "CLOSED"
    2.times { Appointments::ReconcileWorker.new.perform(order.id) }
    assert_equal [ "cancelled", "closed", 1 ], [ order.reload.status, order.payment_status, remaining(order) ]
    assert_equal({ "admin_id" => @operator.id, "reason" => "虚构医生停诊" }, order.payment_data.fetch("staff_cancellation"))
    assert_equal "CLOSED", order_logs(order, "payment_closed").sole.details.fetch("channel_outcome")
  end

  test "a signed lookup miss for a started prepay does not release the seat" do
    order = book!
    # The attempt marker is committed before the network request returns a prepay ID.
    order.update!(payment_data: order.payment_data.merge("prepay_attempted" => true))
    stub_wechat("v3", :get, "#{trade_path(order)}?mchid=#{@merchant_id}", status: 404) { { "code" => "ORDER_NOT_EXIST" } }
    sign_in @operator
    cancel_as_staff(order)
    assert_equal [ "pending_payment", "UNKNOWN", 0 ], [ order.reload.status, order.payment_data.fetch("trade_state"), remaining(order) ]
    assert_empty order_logs(order, "payment_closed")
    @stubs.verify_stubbed_calls
  end

  %w[v2 v3].each do |version|
    test "#{version} reopens the cashier after an interrupted local prepay write" do
      @version = version
      config = WechatPaySettings.new
      assert config.save(payment_settings(version).merge("revision" => config.revision), actor: nil)
      order = book!
      calls = stub_checkout(order)
      # Let the in-flight marker commit, then fail the database write of the returned ID.
      db = Appointment.connection
      constraint = "fixture_interrupted_prepay"
      db.add_check_constraint(:appointments, "id <> #{order.id} OR NOT (payment_data ? 'prepay_id')", name: constraint)
      begin
        post "#{patient_path(order)}/payment", headers: @headers, as: :json
        assert_response :service_unavailable
        assert_equal "payment_unavailable", response.parsed_body.fetch("code")
      ensure
        db.remove_check_constraint(:appointments, name: constraint)
      end
      assert_equal [ 2000 ], calls
      assert_nil order.reload.payment_data["prepay_id"]

      if version == "v2"
        stub_wechat(version, :post, "/pay/orderquery") { payment_result(order, "NOTPAY") }
      else
        stub_query(order) { payment_result(order, "NOTPAY") }
      end
      [ 5, 25 ].each do |minutes|
        travel_to @started_at + minutes.minutes
        Appointments::ReconcileWorker.new.perform(order.id)
        get patient_path(order), headers: @headers, as: :json
        assert response.parsed_body.fetch("can_pay")
        params = post_checkout(order)
        assert_equal "prepay_id=wx_fixture_checkout", params.fetch("package")
        if version == "v2"
          assert_equal v2_signature(params.except("paySign").merge("appId" => @mini_program.appid)), params.fetch("paySign")
        else
          message = [ @mini_program.appid, *params.values_at("timeStamp", "nonceStr", "package"), "" ].join("\n")
          assert @merchant_key.public_key.verify("SHA256", Base64.strict_decode64(params.fetch("paySign")), message)
        end
      end
      assert_equal [ 2000, 2000 ], calls
      assert_equal @started_at + 30.minutes, order.reload.payment_expires_at
      assert_equal 0, remaining(order)
    end

    %w[patient staff expiry].each do |closing|
      test "overlapping #{version} checkout releases one seat and restores quota after rejection and #{closing}" do
        @version = version
        config = WechatPaySettings.new
        assert config.save(payment_settings(version).merge("revision" => config.revision), actor: nil)
        tomorrow = Date.tomorrow
        @doctor.schedules.create!(time_slot: "AM", weekday: tomorrow.wday, start_date: tomorrow, capacity: 8)
        draft = booking_draft.merge(date: tomorrow.iso8601)
        order = book!(draft)
        AppointmentSettings::SLOT_TIMES[16..22].each_cons(2) do |start_at, end_at|
          next if start_at == "09:30"
          book!(draft.merge(idempotency_key: SecureRandom.uuid, start_time: start_at, end_time: end_at))
        end
        extra = draft.merge(idempotency_key: SecureRandom.uuid, start_time: "11:00", end_time: "11:30")
        post_booking(extra)
        assert_equal "daily_limit", response.parsed_body.fetch("code")

        second = open_session
        headers = { "Authorization" => "Bearer #{MiniProgramSession.issue!(@identity).fetch(:token)}" }
        calls = 0
        stub_prepay_rejection(order) do
          calls += 1
          next unless calls == 1

          second.post "#{patient_path(order)}/payment", headers: headers, as: :json
          assert_equal "payment_processing", second.response.parsed_body.fetch("code")
        end
        2.times do
          post "#{patient_path(order)}/payment", headers: @headers, as: :json
          assert_response :service_unavailable
          assert_equal "rejected", order.reload.payment_data["prepay_outcome"]
        end
        get patient_path(order), headers: @headers, as: :json
        assert response.parsed_body.fetch("can_pay")
        assert_equal 2, calls # One original request and one retry after its signed rejection.
        assert_equal 0, remaining(order)
        stub_missing_payment(order)
        case closing
        when "staff"
          sign_in @operator
          cancel_as_staff(order)
        when "patient"
          post "#{patient_path(order)}/cancel", headers: @headers, as: :json
          assert_response :ok
        end
        travel_to @started_at + 12.hours
        3.times { Appointments::ReconcileWorker.new.perform(order.id) }
        assert_equal [ "cancelled", "closed", 1 ], [ order.reload.status, order.payment_status, remaining(order) ]
        assert_equal "ORDER_NOT_CREATED", order_logs(order, "payment_closed").sole.details.fetch("channel_outcome")
        assert_equal @user.id, book!(extra).user_id

        another_user = User.create!(platform: "wechat")
        identity = another_user.user_apps.create!(app: @mini_program, openid: "fixture-second-patient", last_sign_in_at: Time.current)
        @headers = { "Authorization" => "Bearer #{MiniProgramSession.issue!(identity).fetch(:token)}" }
        replacement = book!(draft.merge(idempotency_key: SecureRandom.uuid))
        assert_equal [ another_user.id, 0 ], [ replacement.user_id, remaining(replacement) ]
      end
    end
  end

  test "a signed missing-order lookup during a timed out checkout holds the seat even after later misses" do
    order = book!
    stub_missing_payment(order)
    stub_wechat("v3", :post, "/v3/pay/transactions/jsapi") do
      assert_equal "in_flight", order.reload.payment_data["prepay_outcome"]
      cancellation = open_session
      cancellation.post "#{patient_path(order)}/cancel", headers: @headers, as: :json
      assert_equal 200, cancellation.response.status
      assert_equal "pending_payment", cancellation.response.parsed_body.fetch("status")
      raise Faraday::TimeoutError
    end
    post "#{patient_path(order)}/payment", headers: @headers, as: :json
    assert_response :service_unavailable
    travel_to @started_at + 12.hours
    4.times { Appointments::ReconcileWorker.new.perform(order.id) }
    assert_equal [ "pending_payment", "unknown", "UNKNOWN", 0 ],
      [ order.reload.status, *order.payment_data.values_at("prepay_outcome", "trade_state"), remaining(order) ]
  end

  test "an unverifiable rejection stays ambiguous and a late refusal cannot replace a newer payment" do
    order = book!
    missing = true
    @stubs.get("#{trade_path(order)}?mchid=#{@merchant_id}") do
      body = (missing ? { code: "ORDER_NOT_EXIST" } : payment_result(order, "NOTPAY")).to_json
      [ (missing ? 404 : 200), v3_headers(body), body ]
    end
    calls = 0
    @stubs.post("/v3/pay/transactions/jsapi") do |env|
      assert_equal order.payment_no, JSON.parse(env.body).fetch("out_trade_no")
      calls += 1
      case calls
      when 1
        body = { code: "APPID_MCHID_NOT_MATCH" }.to_json
        [ 400, v3_headers(body).merge("Wechatpay-Signature" => "bad-signature"), body ]
      when 2
        Appointments::ReconcileWorker.new.perform(order.id)
        retry_session = open_session
        retry_session.post "#{patient_path(order)}/payment", headers: @headers, as: :json
        assert_equal "payment_processing", retry_session.response.parsed_body.fetch("code")
        send_notification(order, "payment", payment_result(order), open_session)
        body = { code: "APPID_MCHID_NOT_MATCH" }.to_json
        [ 400, v3_headers(body), body ]
      else
        flunk "Duplicate prepay"
      end
    end

    post "#{patient_path(order)}/payment", headers: @headers, as: :json
    assert_response :service_unavailable
    assert_equal "unknown", order.reload.payment_data.fetch("prepay_outcome")
    Appointments::ReconcileWorker.new.perform(order.id)
    assert_equal [ "pending_payment", 0, "UNKNOWN" ], [ order.reload.status, remaining(order), order.payment_data.fetch("trade_state") ]
    # A signed query confirming an open unpaid order makes checkout available again.
    missing = false
    Appointments::ReconcileWorker.new.perform(order.id)
    post "#{patient_path(order)}/payment", headers: @headers, as: :json
    assert_response :service_unavailable
    assert_equal [ "confirmed", 2000, 0 ], [ order.reload.status, order.paid_amount_cents, remaining(order) ]
    assert_empty order_logs(order, "payment_closed")
  end

  test "six closed pending bookings stop counting against the account on the same visit date" do
    orders = fill_daily_quota
    post_booking(booking_draft.merge(patient_name: "虚构额外家属"))
    assert_equal "daily_limit", response.parsed_body.fetch("code")
    orders.each do |order|
      post "#{patient_path(order)}/cancel", headers: @headers, as: :json
      assert_response :ok
      assert_equal "cancelled", response.parsed_body.fetch("status")
    end
    assert_empty @user.appointments.occupying
    assert_equal "pending_payment", book!.status
  end

  test "the account limit counts completed visits, pending returns and price refunds until a booking is cancelled" do
    returning, visiting = fill_daily_quota
    [ returning, visiting ].each { |order| settle_payment(order) }
    request_return(returning)
    assert_equal "cancel_requested", returning.reload.status

    sign_in @operator
    requests = stub_v3_refunds(visiting)
    post refund_difference_admins_reservation_path(visiting.order_no), params: { refund: refund_form(visiting, reason: "虚构费用调整", amount: "5") }
    send_v3_refund(visiting, requests.sole, 500)
    assert_equal [ "confirmed", "partial" ], visiting.reload.attributes.values_at("status", "refund_status")
    post_booking(booking_draft)
    assert_equal "daily_limit", response.parsed_body.fetch("code")

    patch complete_admins_reservation_path(visiting.order_no)
    assert_equal "completed", visiting.reload.status
    post_booking(booking_draft)
    assert_equal "daily_limit", response.parsed_body.fetch("code")

    stub_v3_refunds(returning)
    review(returning, 1, "approve")
    assert_equal "cancelled", returning.reload.status
    assert_equal "pending_payment", book!.status
  end

  test "refusal retains the seat and a second request after the visit time can be approved the next day" do
    order = book!
    settle_payment(order)
    travel_to @started_at + 40.minutes
    key = SecureRandom.uuid
    request_return(order, key: key)
    request_return(order, key: key)
    assert_equal [ "cancel_requested", "requested", 0, 1 ], [ order.reload.status, order.refund_status, remaining(order), order.refund_items.size ]

    sign_in @operator
    review(order, 1, "reject", "虚构审核：患者希望保留原号")
    get patient_path(order), headers: @headers, as: :json
    assert_equal "confirmed", response.parsed_body.fetch("status")
    assert_match(/保留原号/, response.parsed_body.fetch("refunds").sole.fetch("review_note"))
    assert_equal 0, remaining(order)

    request_return(order)
    travel_to @started_at + 1.day
    requests = stub_v3_refunds(order)
    2.times { review(order, 2, "approve") }
    assert_equal [ 2000 ], requests.map { |row| row.dig("amount", "refund") }
    assert_equal [ "cancelled", "processing", 1 ], [ order.reload.status, order.refund_status, remaining(order) ]
    assert_equal "approve", order.refund_items.last.fetch("review_decision")
    send_v3_refund(order, requests.sole, 2000)
    assert_equal [ "paid", "refunded", 2000 ], order.reload.attributes.values_at("payment_status", "refund_status", "refunded_amount_cents")
  end

  test "consultation consumes the seat and closes return through the page and both interfaces" do
    order = book!
    settle_payment(order)
    request_return(order)
    sign_in @operator
    patch complete_admins_reservation_path(order.order_no)
    assert_response :see_other
    assert_equal [ "completed", @operator.id, @started_at, 0 ], [ order.reload.status, order.completed_by_admin_id, order.completed_at, remaining(order) ]
    assert_equal "rejected", order.refund_items.sole.fetch("status")
    request_return(order, expected: :unprocessable_content)
    post return_booking_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构停诊") }
    follow_redirect!
    assert_includes response.body, "当前预约无法退号"
    refute_includes response.body, "医院退号</button>"
    assert_equal 0, remaining(order)
  end

  test "only staff may initiate a hospital return after the patient's deadline and days off stay closed" do
    order = book!
    settle_payment(order)
    sign_in @operator
    suspend_schedule(order)
    assert_equal [ "confirmed", [] ], [ order.reload.status, order.refund_items ]

    travel_to @started_at + 1.day
    request_return(order, expected: :unprocessable_content)
    support = Admin.create!(username: "fixture_support", role: "customer_service")
    sign_in support
    get admins_reservation_path(order.order_no)
    assert_response :ok
    assert_select "button", text: "退差价", count: 0
    post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构", amount: 5) }
    assert_response :forbidden
    post return_booking_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构停诊") }
    assert_response :forbidden
    sign_in @operator
    requests = stub_v3_refunds(order)
    post return_booking_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构医生停诊") }
    assert_response :see_other
    assert_equal [ "cancelled", "processing", "虚构医生停诊" ], [ order.reload.status, order.refund_status, order.refund_items.sole["reason"] ]
    assert_equal 2000, requests.sole.dig("amount", "refund")
    assert_empty ScheduleCalendar.new([ @doctor.id ], order.appointment_date..order.appointment_date).day_availability(@doctor.id, order.appointment_date)[:shifts]
  end

  [ [], [ 300 ] ].each do |extra_refunds|
    test "a 20 yuan booking pays back #{extra_refunds.empty? ? 15 : 12} yuan after confirmed differences" do
      order = book!
      settle_payment(order)
      sign_in @operator
      requests = stub_v3_refunds(order)
      input = refund_form(order, reason: "虚构费用调整", amount: "5")
      2.times { post refund_difference_admins_reservation_path(order.order_no), params: { refund: input } }
      assert_equal 1, requests.size
      assert_equal [ "confirmed", "processing", 1500, 0 ], [ order.reload.status, order.refund_status, order.available_refund_cents, remaining(order) ]
      [ "", "0", "15.01" ].each do |invalid|
        post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构", amount: invalid) }
        follow_redirect!
        assert_includes response.body, "不超过剩余可退金额"
      end
      2.times { send_v3_refund(order, requests.first, 500) }
      assert_equal [ "confirmed", "partial", 500 ], order.reload.attributes.values_at("status", "refund_status", "refunded_amount_cents")
      extra_refunds.each do |difference|
        post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构再次调价", amount: difference / 100) }
        second = requests.last
        send_v3_refund(order, second, nil)
        assert_nil order.reload.refunded_amount_cents
        assert_equal [ "succeeded", nil ], order.refund_items.last.values_at("status", "payer_refund_cents")
        assert_equal 1200, order.available_refund_cents
        get admins_reservation_path(order.order_no)
        assert_includes response.body, "已确认 5 元，其余待核对"
        post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "虚构额度核对", amount: "12.01") }
        assert_equal 2, requests.size

        stub_wechat("v3", :get, "/v3/refund/domestic/refunds/#{second.fetch('out_refund_no')}") do
          v3_refund_result(order, second, "SUCCESS", difference)
        end
        post sync_refund_admins_reservation_path(order.order_no, order.refund_items.last.fetch("id"))
        assert_response :see_other
        2.times { send_v3_refund(order, second, difference) }
        assert_equal 800, order.reload.refunded_amount_cents
      end
      stale = refund_form(order, reason: "虚构余额变化", confirmed_available: 1500 + extra_refunds.sum + 100)
      post return_booking_admins_reservation_path(order.order_no), params: { refund: stale }
      follow_redirect!
      remaining_cents = 1500 - extra_refunds.sum
      assert_includes response.body, "当前可退 #{remaining_cents / 100} 元，请重新核对并确认"
      assert_equal "confirmed", order.reload.status
      assert_equal 1 + extra_refunds.size, requests.size
      input = refund_form(order, reason: "虚构停诊")
      2.times { post return_booking_admins_reservation_path(order.order_no), params: { refund: input } }
      assert_equal 2 + extra_refunds.size, requests.size
      assert_equal remaining_cents, requests.last.dig("amount", "refund")
      2.times { send_v3_refund(order, requests.last, remaining_cents) }
      assert_equal [ "cancelled", "paid", "refunded", 2000, 1 ], [ order.reload.status, order.payment_status, order.refund_status, order.refunded_amount_cents, remaining(order) ]
      assert_equal 2 + extra_refunds.size, order.refund_items.size
      assert_equal 2 + 2 * extra_refunds.size, order_logs(order, "refund_result").where("details ->> 'channel_outcome' = 'SUCCESS'").count
    end
  end

  test "automatic full return of a V2 coupon order uses gross amount and records actual cash" do
    @version = "v2"
    config = WechatPaySettings.new
    assert config.save(payment_settings(@version).merge("revision" => config.revision), actor: nil)
    start_hospital_notices
    configure_notice("refund_attention", "{failure_reason}")
    automatic_review
    order = book!
    calls = stub_checkout(order)
    post_checkout(order)
    assert_equal [ 2000 ], calls
    settle_payment(order, cash: 1300)
    # The active site version changes. The old order still uses its original V2 profile.
    config = WechatPaySettings.new
    assert config.save(payment_settings("v3").merge("revision" => config.revision), actor: nil), config.errors.full_messages
    gateway_reply = nil
    stub_wechat("v2", :post, "/secapi/pay/refund") do |fields|
      assert_equal %w[2000 2000], fields.values_at("total_fee", "refund_fee")
      gateway_reply = fields.slice("out_trade_no", "out_refund_no", "total_fee", "refund_fee").merge(
        "transaction_id" => order.transaction_no, "refund_id" => "500000000000001", "cash_fee" => "1300"
      )
    end
    request_return(order)
    assert_equal [ "processing", 0, 2000 ], order.reload.attributes.values_at("refund_status", "refunded_amount_cents", "payable_amount_cents")
    detail = gateway_reply.merge("refund_status" => "SUCCESS", "cash_refund_fee" => "1300")
    stub_wechat("v2", :post, "/pay/refundquery") do |fields|
      assert_equal gateway_reply["out_refund_no"], fields["out_refund_no"]
      detail.slice("out_trade_no", "transaction_id", "total_fee", "cash_fee").merge("refund_count" => "1")
        .merge(detail.except("out_trade_no", "transaction_id", "total_fee", "cash_fee").transform_keys { |field| "#{field}_0" })
    end
    detail["refund_status"] = "CHANGE"
    2.times { send_notification(order, "refund", detail) }
    assert_equal ["退款异常，请到微信支付商户平台核对"], delivered_notices
    assert_equal ["processing", 0], order.reload.attributes.values_at("refund_status", "refunded_amount_cents")
    detail["refund_status"] = "SUCCESS"
    2.times { send_notification(order, "refund", detail) }
    assert_equal 1, Notification.count
    assert_equal [ "refunded", 1300, 1300 ], order.reload.attributes.values_at("refund_status", "paid_amount_cents", "refunded_amount_cents")
    assert_equal [ 2000, 1300 ], order.refund_items.sole.values_at("amount_cents", "payer_refund_cents")
  end

  test "free appointments still confirm and a free return only cancels the booking" do
    @doctor.update!(fee: 0)
    automatic_review
    order = book!
    assert_equal [ "confirmed", "paid", "none", 0 ], order.attributes.values_at("status", "payment_status", "payment_channel", "paid_amount_cents")
    request_return(order)
    assert_equal [ "cancelled", "none", 1 ], [ order.reload.status, order.refund_status, remaining(order) ]
    assert_equal [ "succeeded", 0 ], order.refund_items.sole.values_at("status", "amount_cents")
    assert_equal 0, order.refunded_amount_cents
  end

  test "a successful WeChat refund reports an explicit zero cash amount" do
    automatic_review
    order = book!
    settle_payment(order, cash: 0)
    requests = stub_v3_refunds(order)
    request_return(order)
    2.times { send_v3_refund(order, requests.sole, 0) }
    assert_equal [ "refunded", 0 ], order.reload.attributes.values_at("refund_status", "refunded_amount_cents")
    assert_equal 0, order.refund_items.sole.fetch("payer_refund_cents")
    get patient_path(order), headers: @headers, as: :json
    assert_equal "0", response.parsed_body.fetch("refunds").sole.fetch("cash")
  end

  test "hospital opts into review alone before enabling confirmations and cancellations" do
    start_hospital_notices
    configure_notice("return_requested", "{event_name} {patient} {phone_tail} {requested}")
    order = book!
    stub_checkout(order)
    post_checkout(order)
    2.times { settle_payment(order, cash: 1300) }
    assert_empty delivered_notices
    key = SecureRandom.uuid
    2.times { request_return(order, key: key) }
    assert_equal ["退号待审核 虚＊ 0007 20元"], delivered_notices
    review(order, 1, "reject", "保留预约")
    assert_equal "confirmed", order.reload.status
    configure_notice("return_requested", "停用", enabled: false)
    configure_notice("appointment_returned", "{result} {payable} {paid} {requested} {refunded}")
    request_return(order)
    stub_v3_refunds(order)
    2.times { review(order, 2, "approve") }
    assert_equal ["退号待审核 虚＊ 0007 20元", "预约已取消 20元 13元 20元 0元"], delivered_notices

    configure_notice("appointment_confirmed", "{order_no} {paid}")
    automatic_review
    @doctor.update!(fee: 0)
    free = book!
    request_return(free)
    assert_equal ["#{free.order_no} 0元", "预约已取消 0元 0元 0元 0元"], delivered_notices.last(2)
    other = book!
    post return_booking_admins_reservation_path(other.order_no), params: { refund: refund_form(other, reason: "停诊") }
    assert_equal ["#{other.order_no} 0元", "预约已取消 0元 0元 0元 0元"], delivered_notices.last(2)
    assert_equal 6, Notification.count
  end

  test "a close origin survives reconciliation and late payment wins exactly once" do
    start_hospital_notices
    configure_notice("unpaid_cancelled", "{order_no} {result} {paid}")
    configure_notice("appointment_confirmed", "{order_no} {paid}")
    unpaid = book!
    2.times { post "#{patient_path(unpaid)}/cancel", headers: @headers, as: :json }
    assert_equal ["#{unpaid.order_no} 未付款，预约已关单 0元"], delivered_notices
    staff = book!
    cancel_as_staff(staff)
    paid = book!
    stub_checkout(paid)
    post_checkout(paid)
    state = "USERPAYING"
    stub_query(paid) { payment_result(paid, state) }
    post "#{patient_path(paid)}/cancel", headers: @headers, as: :json
    assert_equal 1, Notification.count
    state = "SUCCESS"
    Appointments::ReconcileWorker.new.perform(paid.id)
    settle_payment(paid)
    assert_equal ["#{unpaid.order_no} 未付款，预约已关单 0元", "#{paid.order_no} 20元"], delivered_notices
  end

  test "expanded confirmation drops a blank final chunk for free and signed paid bookings" do
    start_hospital_notices
    prefix = "医🙂" + "文" * 673 + "ab"
    assert_equal 2048, prefix.bytesize + 20
    configure_notice("appointment_confirmed", "#{prefix}{order_no}\n")
    @doctor.update!(fee: 0)
    free = book!
    assert_equal "待就诊", free.reload.status_label
    assert_equal ["#{prefix}#{free.order_no}"], delivered_notices
    automatic_review
    request_return(free)
    @doctor.update!(fee: 20)
    paid = book!
    2.times { settle_payment(paid) }
    assert_equal "待就诊", paid.reload.status_label
    assert_equal ["#{prefix}#{free.order_no}", "#{prefix}#{paid.order_no}"], delivered_notices
    assert_equal 1, Notification.where(subject: paid).count
  end

  test "free confirmations retain mixed lines and record empty or invalid snapshots" do
    start_hospital_notices
    @doctor.update!(fee: 0)
    automatic_review
    configure_notice("appointment_confirmed", "预约成功 {order_no}，支付时间 {paid_at}\n支付时间 {paid_at}\n实付 {paid}")
    free = book!
    assert_equal ["预约成功 #{free.order_no}，支付时间 —\n实付 0元"], delivered_notices
    request_return(free)
    configure_notice("appointment_confirmed", "支付时间 {paid_at}")
    empty = book!
    assert_equal "模板无可发内容", Log.where(target_type: "Appointment", target_id: empty.id, action: "notification.hospital_skipped").sole.details["reason"]
    request_return(empty)
    row = Setting.find_by!(key: Appointments::GroupNotice.setting_key("appointment_confirmed"))
    row.update!(settings: row.settings.merge("messages" => [{ "type" => "text", "content" => { "text" => "历史文案" } }]))
    invalid = book!
    assert_equal "待就诊", invalid.reload.status_label
    get admins_notifications_path(view: "hospital_skips")
    assert_response :ok
    assert_select ".list-group-item", /通知生成或登记失败/
    assert_select "a[href=?]", admins_reservation_path(invalid.order_no)
    assert_select ".list-group-item", /模板无可发内容/
  end

  test "only verified refund exceptions notify once per refund" do
    start_hospital_notices
    configure_notice("refund_attention", "{kind} {refund_no} {requested} {failure_reason}")
    configure_notice("appointment_returned", "{result}")
    order = book!
    settle_payment(order)
    requests = stub_v3_refunds(order)
    results = []
    %w[SUCCESS CLOSED].each do |state|
      post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(order, reason: "调价", amount: 5) }
      request = requests.last
      assert_equal results, delivered_notices
      if state == "SUCCESS"
        results << "退差价 #{request.fetch('out_refund_no')} 5元 退款异常，请到微信支付商户平台核对"
        2.times { send_notification(order, "refund", v3_refund_result(order, request, "ABNORMAL", nil)) }
        assert_equal results, delivered_notices
      end
      2.times { send_notification(order, "refund", v3_refund_result(order, request, state, 500)) }
      results << "退差价 #{request.fetch('out_refund_no')} 5元 退款已关闭" if state == "CLOSED"
      assert_equal results, delivered_notices
      assert_equal "confirmed", order.reload.status
    end
    assert_equal 2, Notification.count
  end

  test "rolled back notices, missing keys and disabled queued templates never reach the group" do
    start_hospital_notices
    configure_notice("appointment_confirmed", "{order_no}")
    @doctor.update!(fee: 0)
    Appointment.transaction(requires_new: true) do
      book!
      assert_equal 1, Notification.count
      raise ActiveRecord::Rollback
    end
    assert_empty Notification.all
    assert_empty Notifications::DeliveryWorker.jobs
    setting = Setting.find_by!(key: "wechat_notifications")
    setting.write_value("webhook_key", nil)
    setting.save!
    free = book!
    assert_empty Notification.all
    automatic_review
    request_return(free)
    setting.write_value("webhook_key", "fixture-hospital-rotated")
    setting.save!
    other = book!
    notice = Notification.sole
    configure_notice("appointment_confirmed", "{order_no}", enabled: false)
    configure_notice("appointment_confirmed", "新预约 {order_no}")
    Notifications::Delivery.run(notice.id)
    assert_equal ["skipped", []], [notice.reload.delivery_outcome, notice.retryable_ids]
    Notifications::Delivery.run(notice.id)
    assert_empty @group_messages
    assert_equal "confirmed", other.reload.status
    request_return(other)
    fresh = book!
    Notifications::Delivery.run(Notification.where(subject: fresh).sole.id)
    assert_equal ["新预约 #{fresh.order_no}"], @group_messages
  end

  test "disabling between parts preserves the receipt and skips only later parts of that event" do
    start_hospital_notices
    @doctor.update!(fee: 0)
    configure_notice("appointment_confirmed", "中" * 674 + "{order_no}{order_no}")
    configure_notice("appointment_returned", "原退号文案")
    order = book!
    automatic_review
    request_return(order)
    @after_group_request = lambda do
      @after_group_request = nil
      configure_notice("appointment_confirmed", "关闭", enabled: false)
      configure_notice("appointment_confirmed", "新文案")
      configure_notice("appointment_returned", "已编辑")
    end
    confirmed = Notification.find_by!(event: "appointment_confirmed")
    Notifications::Delivery.run(confirmed.id)
    assert_equal "部分已跳过", confirmed.reload.status_label
    assert_equal 0, confirmed.results.first.dig("response", "errcode")
    assert_equal "disabled", confirmed.results.last["stage"]
    Notifications::Delivery.run(Notification.find_by!(event: "appointment_returned").id)
    assert_equal [confirmed.messages.first.dig("content", "text"), "原退号文案"], @group_messages
  end

  test "missing event registration gives HTML guidance and rejects preview and save" do
    start_hospital_notices
    event = "appointment_confirmed"
    definitions = Notifications::EventCatalog.definitions
    definition = definitions.delete(event)
    get edit_admins_hospital_notice_path(event: event)
    assert_response :unprocessable_content
    assert_select "[role=alert]", /重启 Web/
    post preview_admins_hospital_notice_path(event: event), as: :json
    assert_response :unprocessable_content
    assert_equal "未登记的通知事件", response.parsed_body["error"]
    patch admins_hospital_notice_path(event: event), as: :json
    assert_response :unprocessable_content
  ensure
    definitions[event] = definition if definition
  end

  test "hospital templates reject unknown variables, legacy review categories and unauthorized writes" do
    start_hospital_notices
    input = { notification_content: { messages: [{ type: "text", content: { text: "{openid}" } }] } }
    patch admins_hospital_notice_path, params: input, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "不可用的变量"
    get edit_admins_hospital_notice_path(event: "passed")
    assert_response :not_found
    sign_in @operator
    get edit_admins_hospital_notice_path
    assert_response :forbidden
    post preview_admins_hospital_notice_path, params: input, as: :json
    assert_response :forbidden
    patch admins_hospital_notice_path, params: input, as: :json
    assert_response :forbidden
    assert_nil Setting.find_by(key: Appointments::GroupNotice.setting_key("appointment_confirmed"))
  end

  test "a failed group delivery preserves payment and retries only the saved message" do
    start_hospital_notices
    configure_notice("appointment_confirmed", "{patient} {paid}")
    order = book!
    @group_code = 93000
    settle_payment(order, cash: 0)
    notice = Notification.sole
    2.times { Notifications::Delivery.run(notice.id) }
    assert_equal ["虚＊ 0元"], @group_messages
    assert_equal ["failed", ["msg_1"]], [notice.reload.status, notice.retryable_ids]
    assert_equal ["confirmed", 0, 0], [order.reload.status, order.paid_amount_cents, remaining(order)]
    refute_match(/fixture-hospital-robot|unsafe-provider-detail|10000000007/, [notice.payload, notice.response_data].to_json)
    configure_notice("appointment_confirmed", "新模板")
    @group_code = 0
    post retry_failed_admins_notification_path(notice), params: {message_ids: notice.retryable_ids}
    Notifications::Delivery.run(notice.id)
    assert_equal ["虚＊ 0元", "虚＊ 0元"], @group_messages
    assert_equal "sent", notice.reload.status
    get admins_notification_path(notice)
    assert_response :ok
    assert_select "details", /93000/
  end

  private

  def order_logs(order, action)
    Log.where(action: "appointment.#{action}", target_type: "Appointment", target_id: order.id)
  end

  def start_hospital_notices
    sign_in Admin.create!(username: "fixture_notice_admin", role: "super_admin")
    get edit_admins_system_settings_wecom_notifications_path
    assert_response :ok
    revision = css_select("input[name='notification_settings[revision]']").sole["value"]
    patch admins_system_settings_wecom_notifications_path, params: {
      notification_settings: { revision: revision, webhook_key: "fixture-hospital-robot" }
    }
    assert_response :redirect
    Notifications::DeliveryWorker.clear
    @group_messages = []
    @stubs.post("/cgi-bin/webhook/send") do |env|
      @group_messages << JSON.parse(env.body).dig("text", "content")
      @after_group_request&.call
      response_for(errcode: @group_code || 0, errmsg: "unsafe-provider-detail")
    end
  end

  def configure_notice(event, text, enabled: true)
    get edit_admins_hospital_notice_path(event: event)
    assert_response :ok
    revision = JSON.parse(css_select("[data-reply-editor]").sole["data-input"]).fetch("revision")
    patch admins_hospital_notice_path(event: event), as: :json, params: {
      notification_content: { enabled: enabled, revision: revision, messages: [{ type: "text", content: { text: text } }] }
    }
    assert_response :ok
  end

  def delivered_notices
    Notifications::DeliveryWorker.drain
    Notification.order(:id).each { |row| assert_equal "sent", row.status }
    @group_messages.dup
  end

  def booking_draft
    { idempotency_key: SecureRandom.uuid, doctor_id: @doctor.id, department_id: @department.id, date: @started_at.to_date.iso8601,
      time_slot: "AM", mode: "slot", start_time: "09:30", end_time: "10:00",
      patient_name: "虚构就诊人", patient_age: 30, patient_gender: 1, patient_mobile: "10000000007" }
  end

  def post_booking(draft)
    post api_mini_program_appointments_path(@mini_program.appid), params: { appointment: draft }, headers: @headers, as: :json
  end

  def book!(draft = booking_draft)
    post_booking(draft)
    assert_response :created
    Appointment.find_by!(order_no: response.parsed_body.fetch("order_no"))
  end

  def fill_daily_quota
    @settings.update!(settings: @settings.settings.merge("max_bookings_per_slot" => 8))
    @doctor.schedules.sole.update!(capacity: 8)
    Array.new(6) { |index| book!(booking_draft.merge(patient_name: "虚构家属#{index}")) }
  end

  def suspend_schedule(order)
    editor = ScheduleEditor.new(doctor: @doctor, actor: @operator, request: nil)
    assert editor.save_date(order.appointment_date, { time_slot: "", capacity: "" }, revision: editor.date_revision(order.appointment_date))
    assert_equal({ "AM" => 1 }, editor.affected_bookings)
  end

  def cancel_as_staff(order, reason: "虚构医生停诊", expected: :see_other)
    post cancel_pending_payment_admins_reservation_path(order.order_no), params: { payment_cancellation: { reason: reason } }
    assert_response expected
  end

  def patient_path(order) = api_mini_program_appointment_path(@mini_program.appid, order.order_no)
  def trade_path(order) = "/v3/pay/transactions/out-trade-no/#{order.payment_no}"

  def remaining(order)
    date = order.appointment_date
    ScheduleCalendar.new([ @doctor.id ], date..date).day_availability(@doctor.id, date, include_times: true)[:shifts].sole[:slots]
      .find { |slot| slot[:start_time] == "09:30" }.fetch(:remaining)
  end

  def stub_prepay_rejection(order)
    if @version == "v2"
      stub_wechat("v2", :post, "/pay/unifiedorder") do |fields|
        yield
        assert_equal order.payment_no, fields.fetch("out_trade_no")
        { "result_code" => "FAIL", "err_code" => "APPID_MCHID_NOT_MATCH" }
      end
    else
      stub_wechat("v3", :post, "/v3/pay/transactions/jsapi", status: 400) do |fields|
        yield
        assert_equal order.payment_no, fields.fetch("out_trade_no")
        { "code" => "APPID_MCHID_NOT_MATCH" }
      end
    end
  end

  def stub_missing_payment(order)
    if @version == "v2"
      stub_wechat("v2", :post, "/pay/orderquery") do |fields|
        assert_equal order.payment_no, fields.fetch("out_trade_no")
        { "result_code" => "FAIL", "err_code" => "ORDERNOTEXIST" }
      end
    else
      stub_wechat("v3", :get, "#{trade_path(order)}?mchid=#{@merchant_id}", status: 404) { { "code" => "ORDER_NOT_EXIST" } }
    end
  end

  def stub_checkout(order)
    calls = []
    path = @version == "v2" ? "/pay/unifiedorder" : "/v3/pay/transactions/jsapi"
    stub_wechat(@version, :post, path) do |fields|
      assert_equal order.payment_no, fields.fetch("out_trade_no")
      if @version == "v2"
        assert_equal @started_at.strftime("%Y%m%d%H%M%S"), fields.fetch("time_start")
        assert_equal order.payment_expires_at.strftime("%Y%m%d%H%M%S"), fields.fetch("time_expire")
        calls << fields.fetch("total_fee").to_i
      else
        assert_equal order.payment_expires_at, Time.iso8601(fields.fetch("time_expire"))
        calls << fields.fetch("amount").fetch("total")
      end
      { "trade_type" => "JSAPI", "prepay_id" => "wx_fixture_checkout" }
    end
    calls
  end

  def post_checkout(order)
    post "#{patient_path(order)}/payment", headers: @headers, as: :json
    assert_response :ok
    response.parsed_body.fetch("payment_params")
  end

  def stub_query(order, &block)
    stub_wechat("v3", :get, "#{trade_path(order)}?mchid=#{@merchant_id}", &block)
  end

  def payment_result(order, state = "SUCCESS", cash: 2000)
    fields = { "out_trade_no" => order.payment_no, "trade_state" => state }
    if @version == "v2"
      return fields.merge("transaction_id" => "420000000000001", "trade_type" => "JSAPI", "openid" => @identity.openid,
        "total_fee" => order.payable_amount_cents.to_s, "cash_fee" => cash.to_s, "time_end" => Time.current.strftime("%Y%m%d%H%M%S"))
    end

    fields.merge!("mchid" => @merchant_id, "appid" => @mini_program.appid)
    return fields unless state == "SUCCESS"

    fields.merge("transaction_id" => "420#{order.payment_no}", "trade_type" => "JSAPI", "payer" => { "openid" => @identity.openid },
      "amount" => { "total" => order.payable_amount_cents, "payer_total" => cash, "currency" => "CNY", "payer_currency" => "CNY" },
      "success_time" => Time.current.iso8601)
  end

  def settle_payment(order, cash: 2000)
    send_notification(order, "payment", payment_result(order, cash: cash))
    assert_equal "paid", order.reload.payment_status
  end

  def send_notification(order, type, data, session = self)
    body, headers = notification_packet(@version, type, data)
    session.post api_wechat_payment_notification_path(version: @version, config_ref: order.payment_data.fetch("config_ref"), kind: type),
      params: body, headers: headers
    assert_equal(@version == "v3" ? 204 : 200, session.response.status)
  end

  def automatic_review
    @settings.update!(settings: @settings.settings.merge("refund_requires_review" => false))
  end

  def request_return(order, key: SecureRandom.uuid, expected: :ok)
    post "#{patient_path(order)}/return_booking", params: { refund: { idempotency_key: key } }, headers: @headers, as: :json
    assert_response expected
  end

  def refund_form(order, reason:, amount: nil, confirmed_available: order.reload.available_refund_cents)
    { idempotency_key: SecureRandom.uuid, reason: reason, amount: amount, confirmed_available: confirmed_available }
  end

  def review(order, id, decision, note = nil)
    item = order.reload.refund_items.find { |record| record.fetch("id") == id }
    available = order.available_refund_cents + item["amount_cents"].to_i
    patch review_refund_admins_reservation_path(order.order_no, id), params: {
      refund: { decision: decision, note: note, confirmed_available: available }
    }
    assert_response :see_other
  end

  def stub_v3_refunds(order)
    requests = []
    stub_wechat("v3", :post, "/v3/refund/domestic/refunds") do |fields|
      assert_equal order.payment_no, fields.fetch("out_trade_no")
      assert_equal order.payable_amount_cents, fields.dig("amount", "total")
      requests << fields
      v3_refund_result(order, fields, "SUCCESS", fields.dig("amount", "refund"))
    end
    requests
  end

  def v3_refund_result(order, request, state, cash)
    amount = request.fetch("amount").merge("payer_refund" => cash, "payer_total" => order.paid_amount_cents).compact
    number = request.fetch("out_refund_no")
    { "out_trade_no" => order.payment_no, "out_refund_no" => number, "transaction_id" => order.reload.transaction_no,
      "refund_id" => "500#{number}", "mchid" => @merchant_id, "refund_status" => state, "status" => state,
      "amount" => amount, "success_time" => Time.current.iso8601 }
  end

  def send_v3_refund(order, request, cash)
    send_notification(order, "refund", v3_refund_result(order, request, "SUCCESS", cash))
  end
end

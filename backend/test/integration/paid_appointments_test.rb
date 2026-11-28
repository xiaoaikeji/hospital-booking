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
    assert_select "button", text: "申请退号", count: 1
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
    post refund_difference_admins_reservation_path(visiting.order_no), params: { refund: refund_form(reason: "虚构费用调整", amount: "5") }
    review(visiting, 1, "approve")
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
    review(order, 2, "approve")
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
    post return_booking_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构停诊") }
    follow_redirect!
    assert_includes response.body, "当前预约无法退号"
    refute_includes response.body, "申请退号</button>"
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
    refute_includes response.body, "申请退差价"
    post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构", amount: 5) }
    assert_response :forbidden
    post return_booking_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构停诊") }
    assert_response :forbidden
    sign_in @operator
    automatic_review
    requests = stub_v3_refunds(order)
    post return_booking_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构医生停诊") }
    assert_response :see_other
    assert_equal [ "cancelled", "processing", "虚构医生停诊" ], [ order.reload.status, order.refund_status, order.refund_items.sole["reason"] ]
    assert_equal 2000, requests.sole.dig("amount", "refund")
    assert_empty ScheduleCalendar.new([ @doctor.id ], order.appointment_date..order.appointment_date).day_availability(@doctor.id, order.appointment_date)[:shifts]
  end

  [ [], [ 300 ] ].each do |extra_refunds|
    test "a 20 yuan booking pays back #{extra_refunds.empty? ? 15 : 12} yuan after confirmed differences" do
      automatic_review
      order = book!
      settle_payment(order)
      sign_in @operator
      requests = stub_v3_refunds(order)
      input = refund_form(reason: "虚构费用调整", amount: "5")
      2.times { post refund_difference_admins_reservation_path(order.order_no), params: { refund: input } }
      assert_equal 1, requests.size
      assert_equal [ "confirmed", "processing", 1500, 0 ], [ order.reload.status, order.refund_status, order.available_refund_cents, remaining(order) ]
      [ "", "0", "15.01" ].each do |invalid|
        post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构", amount: invalid) }
        follow_redirect!
        assert_includes response.body, "不超过剩余可退金额"
      end
      2.times { send_v3_refund(order, requests.first, 500) }
      assert_equal [ "confirmed", "partial", 500 ], order.reload.attributes.values_at("status", "refund_status", "refunded_amount_cents")
      extra_refunds.each do |difference|
        post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构再次调价", amount: difference / 100) }
        second = requests.last
        send_v3_refund(order, second, nil)
        assert_nil order.reload.refunded_amount_cents
        assert_equal [ "succeeded", nil ], order.refund_items.last.values_at("status", "payer_refund_cents")
        assert_equal 1200, order.available_refund_cents
        get admins_reservation_path(order.order_no)
        assert_includes response.body, "已确认 5 元，其余待核对"
        post refund_difference_admins_reservation_path(order.order_no), params: { refund: refund_form(reason: "虚构额度核对", amount: "12.01") }
        assert_equal 2, requests.size

        stub_wechat("v3", :get, "/v3/refund/domestic/refunds/#{second.fetch('out_refund_no')}") do
          v3_refund_result(order, second, "SUCCESS", difference)
        end
        post sync_refund_admins_reservation_path(order.order_no, order.refund_items.last.fetch("id"))
        assert_response :see_other
        2.times { send_v3_refund(order, second, difference) }
        assert_equal 800, order.reload.refunded_amount_cents
      end
      request_return(order)
      remaining_cents = 1500 - extra_refunds.sum
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
    2.times { send_notification(order, "refund", detail) }
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

  private

  def order_logs(order, action)
    Log.where(action: "appointment.#{action}", target_type: "Appointment", target_id: order.id)
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

  def refund_form(reason:, amount: nil)
    { idempotency_key: SecureRandom.uuid, reason: reason, amount: amount }
  end

  def review(order, id, decision, note = nil)
    patch review_refund_admins_reservation_path(order.order_no, id), params: { refund: { decision: decision, note: note } }
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

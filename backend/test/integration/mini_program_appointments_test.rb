require "test_helper"

class MiniProgramAppointmentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include Rails.application.routes.url_helpers

  setup do
    @day = Date.new(2026, 12, 1)
    travel_to @day.in_time_zone.change(hour: 8, min: 50)
    @mini_program = App.create!(provider: "wechat", status: "active", appid: "fixture_free_booking")
    @owner = User.create!(platform: "wechat", nickname: "测试小王")
    @other = User.create!(platform: "wechat")
    @owner_headers = headers_for(@owner, @mini_program)
    @other_headers = headers_for(@other, @mini_program)
    @department = Department.create!(name: "演示全科")
    @other_department = Department.create!(name: "演示复诊")
    @doctor = Doctor.create!(name: "演示医生", departments: [ @department, @other_department ])
    @schedule = @doctor.schedules.create!(weekday: @day.wday, start_date: @day, time_slot: "AM", capacity: 5)
    @settings = Setting.create!(key: "appointment", settings: { "booking_by_time_slot" => true })
    @path = api_mini_program_appointments_path(@mini_program.appid)
    @selection = { doctor_id: @doctor.id, date: @day.iso8601, time_slot: "AM", mode: "slot", start_time: "09:00", end_time: "09:30" }
  end

  test "owning account and admin read the original snapshots after profile and directory edits and the visit end" do
    @owner.verify_mobile!("10000000001")
    hospital = Setting.create!(key: "hospital", settings: { "company_name" => "虚构门诊部", "address" => "示例路 1 号" })
    patient = @owner.patients.create!(name: "测试妈妈", gender: 2, age: 64)
    assert_difference -> { Appointment.count }, 1 do
      submit(patient_id: patient.id, patient_name: "客户端无效姓名", patient_age: 1, remark: "虚构症状")
      assert_response :created
    end
    number = response.parsed_body.fetch("order_no")
    assert_match(/\A[0-9]{20}\z/, number)
    record = Appointment.find_by!(order_no: number)
    assert_equal [ @owner.id, patient.id, @doctor.id, @department.id ], record.attributes.values_at("user_id", "patient_id", "doctor_id", "department_id")
    assert_equal [ "confirmed", "paid", 0, 0, "none", nil ], record.attributes.values_at("status", "payment_status", "fee_cents", "paid_amount_cents", "payment_channel", "transaction_no")
    assert_equal [ "测试妈妈", 64, "10000000002", "虚构症状" ], record.attributes.values_at("patient_name", "patient_age", "patient_mobile", "remark")
    assert_equal "10000000001", @owner.reload.verified_mobile
    audit = Log.find_by!(action: "appointment.create", target_id: record.id)
    assert_equal [ "user", @owner.id, "Appointment", "success", { "order_no" => number } ],
      [ audit.source, audit.actor_id, audit.target_type, audit.status, audit.details ]
    assert_nil audit.ip_address

    patient.update!(name: "测试妈妈新名字", age: 65)
    @doctor.update!(name: "演示医生新名", fee: 2)
    @department.update!(name: "演示全科新名")
    hospital.update!(settings: { "address" => "示例路 2 号" })
    travel 2.hours
    detail = api_mini_program_appointment_path(@mini_program.appid, number)
    get detail, headers: @owner_headers
    assert_response :ok
    assert_equal [ "测试妈妈", 64, "演示医生", "演示全科", "待就诊", "09:00–09:30" ],
      response.parsed_body.values_at("patient_name", "patient_age", "doctor_name", "department_name", "status_label", "slot_label")
    assert_equal "示例路 1 号", response.parsed_body.dig("hospital_snapshot", "address")
    get @path, headers: @owner_headers
    assert_response :ok
    row = response.parsed_body.fetch("appointments").sole
    assert_equal number, row.fetch("order_no")
    assert_not row.key?("patient_mobile")
    get detail, headers: @other_headers
    assert_response :not_found
    get @path, headers: @other_headers
    assert_empty response.parsed_body.fetch("appointments")
    sharing_app = App.create!(provider: "wechat", status: "active", appid: "fixture_shared_booking")
    get api_mini_program_appointment_path(sharing_app.appid, number), headers: headers_for(@owner, sharing_app)
    assert_response :ok

    get admins_reservation_path(number)
    assert_redirected_to new_admin_session_path
    Admin::ROLES.each_key do |role|
      sign_in Admin.create!(username: "reservation_#{role}", role: role)
      get admins_reservations_path, params: { q: number }
      assert_response :ok
      assert_select "td a", text: number
      get admins_reservation_path(number)
      assert_response :ok
      [ "测试妈妈", "64 岁", "演示医生", "演示全科", "10000000002" ].each { |value| assert_select "dd", text: value }
      assert_select ".badge", text: "待就诊"
      assert_select "a, button", text: /编辑预约|取消预约|删除预约|开始服务/, count: 0
    end
    get admins_reservation_previews_path
    assert_response :ok
    assert_includes response.body, "预约演示"
    refute_includes response.body, number
  end

  test "reservation time filtering uses the saved booking window and current hospital shifts before pagination" do
    submit
    assert_response :created
    base = Appointment.sole
    base.update!(time_slot: "FULL")
    sample = lambda do |shift, clock, label|
      starts = Time.zone.parse("#{@day} #{clock}") if clock
      copy = base.dup
      copy.update!(time_slot: shift, slot_label: label, booking_start_at: starts, booking_end_at: starts && starts + 30.minutes,
        idempotency_key: SecureRandom.uuid, order_no: Appointment.generate_order_no)
      copy.order_no
    end
    morning = sample.call("AM", nil, "上午 09:00–09:30")
    first = sample.call("AM", "08:00", "08:00–08:30")
    last = sample.call("FULL", "11:30", "11:30–12:00")
    noon = sample.call("FULL", "12:00", "12:00–12:30")
    evening = sample.call("NIGHT", "17:00", "17:00–17:30")
    full = sample.call("FULL", nil, "全天 08:00–17:00")
    sign_in Admin.create!(username: "filter_operator", role: "operator")
    results = lambda do |value|
      get admins_reservations_path, params: { booking_time: value, department_id: @department.id }
      assert_response :ok
      css_select("tbody tr td:nth-child(2) a").map { |link| link.text.strip }.sort
    end
    assert_equal [ morning, first, base.order_no, last ].sort, results.call("AM")
    assert_equal [ noon ], results.call("PM")
    assert_equal [ evening ], results.call("NIGHT")
    assert_equal [ full ], results.call("FULL")
    assert_equal [ base.order_no ], results.call("09:00–09:30")

    @settings.update!(settings: { "booking_morning_end_at" => "11:30" })
    assert_equal [ morning, first, base.order_no ].sort, results.call("AM")
    assert_equal [ last ], results.call("11:30–12:00")
    assert_select "tbody td", text: /11:30–12:00/
    @settings.update!(settings: { "booking_morning_begin_at" => "09:00", "booking_morning_end_at" => "09:30" })
    assert_equal [ morning, base.order_no ].sort, results.call("AM")
    assert_equal [ base.order_no ], results.call("09:00–09:30")

    20.times { sample.call("AM", nil, "上午 09:00–09:30") }
    options = %w[08:00–08:30 09:00–09:30 11:30–12:00 12:00–12:30 17:00–17:30]
    [ 1, 2 ].each do |page|
      get admins_reservations_path, params: { page: page }
      assert_equal options, css_select("#booking_time option").map(&:text).grep(/–/)
    end
    get admins_reservations_path, params: { department_id: @other_department.id }
    assert_empty css_select("#booking_time option").map(&:text).grep(/–/)
  end

  test "a selected half hour stays visible when another department has only a later booking" do
    submit
    assert_response :created
    submit(department_id: @other_department.id, start_time: "09:30", end_time: "10:00")
    assert_response :created
    other_number = response.parsed_body.fetch("order_no")
    sign_in Admin.create!(username: "filter_operator", role: "operator")

    slot = "09:00–09:30"
    get admins_reservations_path, params: { department_id: @other_department.id, booking_time: slot }
    assert_select "#booking_time option[selected]", text: slot
    assert_select "tbody tr", count: 0
    get admins_reservations_path, params: { department_id: @other_department.id, booking_time: "" }
    assert_select "tbody tr", count: 1
    assert_select "td a", text: other_number
  end

  test "replay precedes fee, cutoff and availability and never saves a second frequent patient" do
    @schedule.update!(capacity: 1)
    payload = { idempotency_key: "fixture-retry-after-response-loss", save_patient: true }
    assert_difference [ -> { Appointment.count }, -> { @owner.patients.count } ], 1 do
      submit(**payload)
      assert_response :created
    end
    number = response.parsed_body.fetch("order_no")
    assert_equal 0, published_shift.fetch("remaining")
    @doctor.update!(fee: 9)
    travel 10.minutes
    assert_no_difference [ -> { Appointment.count }, -> { @owner.patients.count }, -> { Log.where(action: "appointment.create").count } ] do
      submit(**payload)
      assert_response :ok
      assert_equal [ number, "replayed" ], response.parsed_body.values_at("order_no", "outcome")
    end
  end

  test "a saved patient gets the existing booking for the same half hour, across departments and an all-day override" do
    patient = @owner.patients.create!(name: "测试妈妈", gender: 2, age: 64)
    submit(patient_id: patient.id)
    assert_response :created
    first = response.parsed_body.fetch("order_no")
    change_shift("FULL")
    submit(patient_id: patient.id, time_slot: "FULL", department_id: @other_department.id)
    assert_response :ok
    assert_equal [ first, "already_booked" ], response.parsed_body.values_at("order_no", "outcome")

    submit(patient_id: patient.id, time_slot: "FULL", start_time: "09:30", end_time: "10:00")
    assert_response :created
    another = @owner.patients.create!(name: "测试妈妈", gender: 2, age: 65)
    submit(patient_id: another.id, time_slot: "FULL")
    assert_response :created

    assert_no_difference -> { Appointment.count } do
      submit(time_slot: "FULL", patient_name: patient.name, save_patient: true)
      assert_rejected "same_name"
    end
    submit(time_slot: "FULL", patient_name: patient.name, confirm_same_name: true)
    assert_response :created
    assert_equal 1, published_shift.fetch("remaining")
  end

  test "whole-shift duplicate uses the original shift even if the configured times change" do
    @settings.update!(settings: {})
    patient = @owner.patients.create!(name: "测试就诊人", gender: 2, age: 40)
    submit(patient_id: patient.id, mode: "shift", start_time: "08:00", end_time: "12:00")
    assert_response :created
    first = response.parsed_body.fetch("order_no")
    @settings.update!(settings: { "booking_morning_end_at" => "11:30" })
    submit(patient_id: patient.id, mode: "shift", start_time: "08:00", end_time: "11:30")
    assert_response :ok
    assert_equal [ first, "already_booked" ], response.parsed_body.values_at("order_no", "outcome")
  end

  test "write rejects at exact half-hour start and exact whole shift end after confirmation saw a seat" do
    assert checked.fetch("bookable")
    travel 10.minutes
    assert_no_difference [ -> { Appointment.count }, -> { @owner.patients.count } ] do
      submit(save_patient: true)
      assert_rejected "slot_closed"
    end
    @settings.update!(settings: {})
    whole = { mode: "shift", start_time: "08:00", end_time: "12:00" }
    travel_to @day.in_time_zone.change(hour: 11, min: 59, sec: 59)
    assert checked(**whole).fetch("bookable")
    travel 1.second
    assert_no_difference -> { Appointment.count } do
      submit(**whole)
      assert_rejected "slot_closed"
    end
  end

  test "four actual morning bookings leave one all-day seat and preserve their original windows" do
    4.times do |index|
      submit(patient_name: "虚构就诊人#{index}")
      assert_response :created
    end
    assert_equal [ "AM", 1 ], published_shift.values_at("time_slot", "remaining")
    operator = Admin.create!(username: "fixture_schedule_operator", role: "operator")
    sign_in operator
    editor = ScheduleEditor.new(doctor: @doctor, actor: operator, request: nil)
    patch date_adjustment_admins_doctor_schedule_path(@doctor), params: {
      date: @day.iso8601, revision: editor.date_revision(@day), date_adjustment: { time_slot: "PM", capacity: "5" }
    }
    assert_response :see_other
    follow_redirect!
    assert_includes response.body, "上午已有 4 笔预约，请联系受影响的患者"
    assert_equal [ "PM", 5 ], published_shift.values_at("time_slot", "remaining")
    change_shift("FULL")
    full = published_shift
    assert_equal [ "FULL", 5, 1 ], full.values_at("time_slot", "total", "remaining")
    assert_equal 1, full.fetch("slots").find { |slot| slot["start_time"] == "09:00" }.fetch("remaining")
    submit(time_slot: "FULL", start_time: "14:00", end_time: "14:30")
    assert_response :created
    assert_equal 0, published_shift.fetch("remaining")
    assert_equal [ [ "AM", "09:00–09:30" ] ] * 4, @owner.appointments.where(time_slot: "AM").pluck(:time_slot, :slot_label)
  end

  test "a booked half-hour stays full when hospital hours move it to another shift" do
    @settings.update!(settings: @settings.settings.merge(Schedule::NIGHT_SETTING => true))
    @schedule.update!(time_slot: "PM")
    @doctor.schedules.create!(weekday: @day.wday, start_date: @day, time_slot: "NIGHT", capacity: 10)
    afternoon = { time_slot: "PM", start_time: "16:30", end_time: "17:00" }
    5.times do |index|
      submit(patient_name: "满号示例#{index}", **afternoon)
      assert_response :created
    end
    @settings.update!(settings: @settings.settings.merge(
      "booking_afternoon_end_at" => "16:30", "booking_evening_begin_at" => "16:30"
    ))
    night = published_shift("NIGHT")
    assert_equal 5, night.fetch("remaining")
    assert_equal [ "16:30", "17:00", 0 ], night.fetch("slots").first.values_at("start_time", "end_time", "remaining")
    assert_equal 5, published_shift("PM").fetch("remaining")

    evening = afternoon.merge(time_slot: "NIGHT")
    assert_not checked(**evening).fetch("bookable")
    submit(patient_name: "满号示例重选", **evening)
    assert_rejected "slot_full"
    assert_equal [ [ "PM", "16:30–17:00" ] ] * 5, @owner.appointments.pluck(:time_slot, :slot_label)
  end

  test "component actions and container examples open their demo reservation" do
    sign_in Admin.create!(username: "fixture_component_operator", role: "operator")
    get admins_components_path(tab: "actions")
    assert_response :ok
    assert_select "a[href=?]", admins_reservation_preview_path(1)
    assert_select "a[href=?]", edit_admins_reservation_preview_path(1)
    get admins_components_path(tab: "containers")
    assert_response :ok
    assert_select "a[href=?]", admins_reservation_preview_path(1), text: "完整详情"
    get admins_reservation_preview_path(1)
    assert_response :ok
  end

  test "invalid department, symptoms and phone requirements never consume a seat or save a patient" do
    outside = Department.create!(name: "未关联科室")
    foreign_patient = @other.patients.create!(name: "他人档案", gender: 1, age: 40)
    @settings.update!(settings: @settings.settings.merge("require_booking_remark" => true, "require_mobile_auth" => true))
    assert_no_difference [ -> { Appointment.count }, -> { @owner.patients.count } ] do
      submit(patient_id: foreign_patient.id)
      assert_rejected "patient_not_found"
      submit(department_id: outside.id, save_patient: true)
      assert_rejected "department_unavailable"
      submit(remark: " \u3000 ", save_patient: true)
      assert_rejected "symptoms_required"
      submit(remark: "虚构症状", save_patient: true)
      assert_rejected "phone_required"
    end
    assert_equal 5, published_shift.fetch("remaining")
    assert Log.where(action: "appointment.create", status: "failed").all? { |log| log.details.keys == [ "reason" ] }
    @owner.verify_mobile!("10000000001")
    @doctor.update!(fee: 9.5)
    assert_no_difference [ -> { Appointment.count }, -> { @owner.patients.count } ] do
      submit(remark: "虚构症状", save_patient: true)
      assert_response :service_unavailable
      assert_equal "payment_unavailable", response.parsed_body.fetch("code")
    end
    @doctor.update!(fee: 0)
    submit(remark: "虚构症状", save_patient: true)
    assert_response :created
  end

  private

  def headers_for(user, app)
    identity = user.user_apps.create!(app: app, openid: "fixture-#{user.id}")
    { "Authorization" => "Bearer #{MiniProgramSession.issue!(identity).fetch(:token)}" }
  end

  def submit(**changes)
    draft = @selection.merge(
      department_id: @department.id, idempotency_key: SecureRandom.uuid,
      patient_name: "虚构就诊人", patient_age: 38, patient_gender: 2, patient_mobile: "10000000002"
    )
    post @path, params: { appointment: draft.merge(changes) }, headers: @owner_headers, as: :json
  end

  def assert_rejected(code)
    assert_response :unprocessable_content
    assert_equal code, response.parsed_body.fetch("code")
  end

  def checked(**changes)
    get api_mini_program_appointment_check_path(@mini_program.appid), params: @selection.merge(changes), headers: @owner_headers
    assert_response :ok
    response.parsed_body
  end

  def published_shift(time_slot = nil)
    get api_app_configuration_path("wechat", @mini_program.appid), params: { schedule_format: "time_slots" }
    assert_response :ok
    shifts = response.parsed_body.fetch("schedule").first.fetch("availability").fetch(@doctor.id.to_s)
    time_slot ? shifts.find { |shift| shift["time_slot"] == time_slot } : shifts.sole
  end

  def change_shift(shift)
    override = @doctor.schedules.find_or_initialize_by(start_date: @day, end_date: @day)
    override.update!(weekday: @day.wday, time_slot: shift, capacity: 5)
  end
end

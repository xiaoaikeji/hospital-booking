require "test_helper"

class DoctorSchedulesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @operator = Admin.create!(username: "schedule_operator", role: "operator")
    @super_admin = Admin.create!(username: "schedule_admin", role: "super_admin")
    departments = %w[耳鼻喉科 五官门诊].map { |name| Department.create!(name: name) }
    @doctor = Doctor.create!(name: "张医生", departments: departments)
    @mini_program = App.create!(provider: "wechat", app_type: "mini_program", appid: "wx0000000000000091", nickname: "排班验收", status: "active")
    @monday = Date.new(2026, 11, 30)
    travel_to Time.zone.local(2026, 11, 25, 9)
    sign_in @operator
  end

  test "a whole date adjustment replaces the week and clearing survives until it is revoked" do
    get admins_doctor_path(@doctor)
    assert_select "a[href=?]", admins_doctor_schedule_path(@doctor), text: "排班"
    patch weekly_admins_doctor_schedule_path(@doctor), params: { weekly_schedule: { "1" => { time_slot: "AM", capacity: "" } } }
    assert_response :see_other
    assert_nil @doctor.schedules.weekly.sole.capacity
    assert_calendar %w[AM]
    get adjustment_page
    assert_select "#adjustment-time-slot option[selected][value='AM']"

    adjust(time_slot: "PM", capacity: "9")
    assert_response :see_other
    follow_redirect!
    assert_select "#adjustment-time-slot option[selected][value='PM']"
    assert_select "#adjustment-capacity[value='9']"
    assert_calendar %w[PM]

    sign_in @super_admin
    patch night_shift_admins_system_settings_appointment_path, params: { booking_enable_evening: "1" }
    assert_response :see_other
    sign_in @operator
    adjust(time_slot: "PM", capacity: "9", night: "1", night_capacity: "3")
    assert_response :see_other
    assert_calendar %w[PM NIGHT]
    assert_equal 3, @doctor.schedules.on_date(@monday).find_by!(time_slot: "NIGHT").capacity

    adjust(time_slot: "", capacity: "9", night: "0", night_capacity: "3")
    assert_response :see_other
    assert_off

    adjust(time_slot: "", night: "1")
    assert_response :see_other
    assert_equal "NIGHT", @doctor.schedules.on_date(@monday).sole.time_slot
    assert_calendar %w[NIGHT]

    adjust(time_slot: "", night: "0")
    assert_off
    delete date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: @monday.iso8601 }
    assert_redirected_to adjustment_page
    assert_empty @doctor.schedules.on_date(@monday)
    assert_calendar %w[AM]

    events = Log.operations_visible_to(@operator).where(action: %w[schedule.create schedule.update schedule.revoke]).order(:id)
    assert_equal %w[schedule.create schedule.create schedule.update schedule.update schedule.update schedule.update schedule.revoke], events.pluck(:action)
    revoke = events.last
    assert_equal [ "success", "Schedule", @doctor.id, @monday.iso8601 ],
      [ revoke.status, revoke.target_type, *revoke.details.values_at("doctor_id", "schedule_date") ]
    get admins_operation_log_path(revoke)
    assert_response :success
    assert_select "dd", text: @monday.iso8601
  end

  test "customer service can read either form but cannot save or revoke an adjustment" do
    adjust(time_slot: "FULL")
    assert_response :see_other
    customer_service = Admin.create!(username: "schedule_customer_service", role: "customer_service")
    sign_in customer_service

    get admins_doctor_schedule_path(@doctor)
    assert_response :success
    assert_select "#weekday-1-time-slot[disabled]"
    assert_select "button", text: "保存每周排班", count: 0
    get adjustment_page
    assert_response :success
    assert_select "#adjustment-time-slot[disabled] option[selected][value='FULL']"
    assert_select "button", text: /保存日期调整|撤销日期调整/, count: 0
    assert_no_difference [ "Schedule.count", "Log.where(category: 'booking').count" ] do
      patch weekly_admins_doctor_schedule_path(@doctor), params: { weekly_schedule: { "1" => { time_slot: "PM" } } }
      assert_response :forbidden
      adjust(time_slot: "PM")
      assert_response :forbidden
      delete date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: @monday.iso8601 }
      assert_response :forbidden
    end
    assert_equal "FULL", @doctor.schedules.on_date(@monday).sole.time_slot
  end

  test "zero capacity and a disabled night shift do not overwrite the date" do
    adjust(time_slot: "AM", capacity: "7")
    assert_response :see_other
    adjust(time_slot: "PM", capacity: "0")
    assert_response :unprocessable_content
    assert_select ".alert-danger", text: /日间号数请输入正整数或留空/
    adjust(time_slot: "", night: "1")
    assert_response :unprocessable_content
    assert_select ".alert-danger", text: /医院尚未启用晚班/
    assert_equal [ "AM", 7 ], @doctor.schedules.on_date(@monday).sole.slice(:time_slot, :capacity).values
    assert_equal [ "failed", "failed" ], Log.where(action: "schedule.update", actor_id: @operator.id).order(:id).pluck(:status)
  end

  private

  def adjustment_page = admins_doctor_schedule_path(@doctor, tab: "date", date: @monday.iso8601)

  def adjust(**fields)
    patch date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: @monday.iso8601, date_adjustment: fields }
  end

  def assert_calendar(monday_slots)
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_response :success
    directory = response.parsed_body.fetch("directory")
    assert_equal @doctor.department_ids.map(&:to_s).sort, directory.fetch("doctors").sole.fetch("department_ids").sort
    days = response.parsed_body.fetch("schedule").index_by { |day| day.fetch("date") }
    assert_equal 14, days.size
    assert_equal monday_slots, days.fetch(@monday.iso8601).fetch("doctors").fetch(@doctor.id.to_s, [])
    assert_equal %w[AM], days.fetch((@monday + 7).iso8601).fetch("doctors").fetch(@doctor.id.to_s)
  end

  def assert_off
    row = @doctor.schedules.on_date(@monday).sole
    assert_equal "OFF", row.time_slot
    assert_nil row.capacity
    get adjustment_page
    assert_response :success
    assert_select ".badge", text: "已调整"
    assert_select ".badge", text: "当日无班"
    assert_select "#adjustment-time-slot option[selected][value='']"
    assert_select "#adjustment-night[checked]", count: 0
    assert_calendar []
  end
end

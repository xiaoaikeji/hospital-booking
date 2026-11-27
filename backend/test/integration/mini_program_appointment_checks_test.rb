require "test_helper"

class MiniProgramAppointmentChecksTest < ActionDispatch::IntegrationTest
  include Rails.application.routes.url_helpers

  setup do
    @date = Date.new(2026, 11, 30)
    travel_to @date.in_time_zone.change(hour: 11, min: 29, sec: 58)
    @mini_program = App.create!(provider: "wechat", appid: "clinic_appointment_checks_test", status: "active")
    user = User.create!(platform: "wechat")
    identity = user.user_apps.create!(app: @mini_program, openid: "check-fixture")
    @headers = { "Authorization" => "Bearer #{MiniProgramSession.issue!(identity).fetch(:token)}" }
    @doctor = Doctor.create!(name: "测试医生")
    @schedule = @doctor.schedules.create!(weekday: @date.wday, start_date: @date, time_slot: "AM", capacity: 20)
    @settings = Setting.create!(key: "appointment", settings: { "booking_by_time_slot" => true })
    @selection = { doctor_id: @doctor.id, date: @date.iso8601, time_slot: "AM", mode: "slot", start_time: "11:30", end_time: "12:00" }
  end

  test "confirmation judges the exact selection and the current settings independently of an older calendar" do
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid), params: { schedule_format: "time_slots" }
    assert_response :ok
    old = response.parsed_body
    last_slot = old.dig("schedule", 0, "availability", @doctor.id.to_s, 0, "slots").last
    assert_operator last_slot.fetch("cutoff_at"), :>, old.fetch("server_time")

    get api_mini_program_appointment_check_path(@mini_program.appid), params: @selection
    assert_response :unauthorized
    assert checked.fetch("bookable")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not checked(start_time: "11:00").fetch("bookable")
    assert_not checked(end_time: "12:30").fetch("bookable")
    assert_not checked(doctor_id: "#{@doctor.id}x").fetch("bookable")
    assert_not checked(date: (@date + ScheduleCalendar::DAYS).iso8601).fetch("bookable")

    travel 2.seconds
    @settings.update!(settings: { "booking_by_time_slot" => true, "require_mobile_auth" => true, "require_booking_remark" => true })
    assert_equal [ false, true, true ], checked.values_at("bookable", "booking_phone_required", "booking_symptoms_required")

    @settings.update!(settings: {})
    assert_not checked.fetch("bookable")
    whole_shift = { mode: "shift", start_time: "08:00" }
    travel 29.minutes + 59.seconds
    assert_equal [ true, false, false ], checked(**whole_shift).values_at("bookable", "booking_phone_required", "booking_symptoms_required")
    travel 1.second
    assert_not checked(**whole_shift).fetch("bookable")
  end

  test "the confirmation uses the current date override and shared capacity" do
    counts = { [ @doctor.id, @date, "AM" ] => { "08:00" => 1 } }
    @schedule.update!(capacity: 1)
    calendar = ScheduleCalendar.new([ @doctor.id ], @date..@date)
    calendar.define_singleton_method(:occupied_counts) { counts }
    assert_not calendar.bookable_selection?(@doctor.id, @date, **@selection.slice(:time_slot, :mode, :start_time, :end_time))

    @doctor.schedules.create!(weekday: @date.wday, start_date: @date, end_date: @date, time_slot: "PM", capacity: 1)
    assert_not checked.fetch("bookable")
    assert checked(time_slot: "PM", start_time: "12:00", end_time: "12:30").fetch("bookable")
  end

  private

  def checked(**changes)
    get api_mini_program_appointment_check_path(@mini_program.appid), params: @selection.merge(changes), headers: @headers
    assert_response :ok
    response.parsed_body
  end
end

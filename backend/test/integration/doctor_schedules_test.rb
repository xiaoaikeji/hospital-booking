require "test_helper"
require "zip"

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

  test "the calendar reads the viewed month and distinguishes closed days from hidden night shifts" do
    set_nights(true)
    @doctor.schedules.create!(weekday: 1, start_date: Date.current, time_slot: "AM", capacity: 100)
    @doctor.schedules.create!(weekday: 2, start_date: Date.current, time_slot: "FULL")
    %w[PM NIGHT].zip([ 60, 20 ]).each { |slot, capacity| dated_shift(Date.new(2026, 12, 21), slot, capacity: capacity) }
    dated_shift(Date.new(2026, 12, 23), "OFF")
    dated_shift(Date.new(2026, 12, 24), "NIGHT", capacity: 30)

    days = calendar_days("2026-12")
    assert_equal Date.new(2026, 12, 1).all_month.map(&:iso8601), days.keys
    assert_equal [ shift("AM", "上午", 100) ], days.fetch("2026-12-14").fetch("shifts")
    assert_equal [ shift("FULL", "全天", 20) ], days.fetch("2026-12-22").fetch("shifts")
    assert_equal({ "adjusted" => true, "off" => false, "shifts" => [ shift("PM", "下午", 60), shift("NIGHT", "晚班", 20) ] }, days.fetch("2026-12-21"))
    assert_equal({ "adjusted" => true, "off" => true, "shifts" => [] }, days.fetch("2026-12-23"))
    assert_equal [ shift("NIGHT", "晚班", 30) ], days.fetch("2026-12-24").fetch("shifts")
    assert_equal({ "adjusted" => false, "off" => false, "shifts" => [] }, days.fetch("2026-12-25"))

    set_nights(false)
    days = calendar_days("2026-12")
    assert_equal [ shift("PM", "下午", 60) ], days.fetch("2026-12-21").fetch("shifts")
    assert_equal({ "adjusted" => true, "off" => false, "shifts" => [] }, days.fetch("2026-12-24"))
  end

  test "a read-only operator can refresh the server clock used by the calendar" do
    sign_in Admin.create!(username: "calendar_customer_service", role: "customer_service")
    path = clock_admins_doctor_schedule_path(@doctor)
    get admins_doctor_schedule_path(@doctor)
    assert_select "#doctor-schedule-calendar[data-clock-url=?][data-server-time=?]", path, (Time.current.to_i * 1000).to_s

    travel 2.minutes
    get path
    assert_response :ok
    assert_equal({ "server_time" => Time.current.to_i * 1000 }, response.parsed_body)
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "export includes the matching doctor beyond page one and matches every shift in the month calendar" do
    department = @doctor.departments.ordered.first
    @doctor.update!(status: 0, sort_order: 99, display_on_homepage: false)
    20.times do |index|
      Doctor.create!(name: "张医师 #{index + 1}", status: 0, display_on_homepage: false, departments: [ department ])
    end
    Doctor.create!(name: "张医生（展示）", status: 0, display_on_homepage: true, departments: [ department ])
    Doctor.create!(name: "张医生（启用）", status: 1, display_on_homepage: false, departments: [ department ])
    Doctor.create!(name: "张医生（无科室）", status: 0, display_on_homepage: false)
    filters = { q: "张", department_id: department.id, status: 0, display_on_homepage: "0" }

    get admins_doctors_path, params: filters
    assert_select "tbody tr", count: 20
    assert_select "a[href=?]", admins_doctors_path(**filters, page: 2), text: "下一页"
    get admins_doctors_path, params: filters.merge(page: 2)
    assert_select "tbody tr", count: 1
    assert_select "#doctor_#{@doctor.id}", count: 1

    set_nights(false)
    @doctor.schedules.create!(weekday: 1, start_date: Date.current, time_slot: "AM")
    @doctor.schedules.create!(weekday: 1, start_date: Date.current, time_slot: "NIGHT", capacity: 8)
    dated_shift(Date.new(2026, 12, 7), "PM", capacity: 12)
    dated_shift(Date.new(2026, 12, 14), "OFF")
    month = "2026-12"
    expected = calendar_days(month).flat_map do |date, day|
      day.fetch("shifts").map do |shift|
        override = @doctor.schedules.on_date(Date.iso8601(date)).find_by(time_slot: shift.fetch("time_slot"))
        [ date, @doctor.name, @doctor.department_names, shift.fetch("label"), override&.capacity&.to_s ]
      end
    end

    post export_schedule_admins_doctors_path, params: filters.merge(month:, page: 1)
    assert_response :success
    assert_equal ScheduleExport::CONTENT_TYPE, response.media_type
    headers, *rows = exported_rows
    assert_equal %w[日期 医生 所属科室 班次 班次号数], headers
    assert_equal expected, rows.map { |serial, *fields| [ (Date.new(1899, 12, 30) + serial.to_i).iso8601, *fields ] }
    assert_equal 3, rows.size
    event = Log.operations_visible_to(@operator).find_by!(action: "schedule.export")
    assert_equal "success", event.status
    assert_equal({ "schedule_month" => month, "name_filtered" => true, "department_id" => department.id,
      "doctor_status" => "已停用", "display_on_homepage" => false, "row_count" => rows.size }, event.details)

    sign_in Admin.create!(username: "export_customer_service", role: "customer_service")
    get admins_doctors_path, params: filters.merge(page: 2)
    assert_select "#doctor_#{@doctor.id}", count: 1
    assert_select "#doctor-schedule-export", count: 0
    post export_schedule_admins_doctors_path, params: filters.merge(month:)
    assert_response :forbidden
  end

  test "both calendars share the current hospital default and preserve explicit capacity" do
    set_nights(true)
    dated_shift(@monday, "FULL", capacity: 30)
    dated_shift(@monday, "NIGHT", capacity: 5)
    blank_date = @monday - 1
    dated_shift(blank_date, "FULL")

    explicit = [ shift("FULL", "全天", 30), shift("NIGHT", "晚班", 5) ]
    assert_published_schedule({ @monday => explicit, blank_date => [ shift("FULL", "全天", 20) ] })
    get admins_doctor_schedule_path(@doctor, tab: "date", date: blank_date.iso8601)
    assert_select "#adjustment-capacity[placeholder='默认：20']:not([value])"
    assert_select "#adjustment-night-capacity:not([placeholder])"

    sign_in @super_admin
    get edit_admins_system_settings_appointment_path
    assert_select "#appointment_default_capacity[value='20']"
    revision = AppointmentSettings.new.revision
    patch admins_system_settings_appointment_path, params: {
      appointment: { revision:, require_mobile_auth: "0", booking_enable_evening: "1", default_capacity: "25" }
    }
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal [ "default_capacity" ], Log.where(action: "appointment.update").last.details.fetch("fields")
    assert_nil @doctor.schedules.on_date(blank_date).sole.capacity
    assert_published_schedule({ @monday => explicit, blank_date => [ shift("FULL", "全天", 25) ] })
    assert_equal @doctor.department_ids.map(&:to_s).sort, response.parsed_body.dig("directory", "doctors").sole.fetch("department_ids").sort

    counts = { [ @doctor.id, @monday, "FULL" ] => { nil => 7 }, [ @doctor.id, @monday, "NIGHT" ] => { nil => 6 } }
    calendar = ScheduleCalendar.new([ @doctor.id ], blank_date..@monday)
    calendar.define_singleton_method(:occupied_counts) { counts }
    assert_equal [ [ 30, 23 ], [ 5, 0 ] ], calendar.day_availability(@doctor.id, @monday).fetch(:shifts).map { |row| row.values_at(:total, :remaining) }
    assert_equal 25, calendar.day_availability(@doctor.id, blank_date).fetch(:shifts).sole.fetch(:remaining)
  end

  test "time-slot mode computes the capacity of each shift without rewriting the saved number" do
    dates = @monday..(@monday + 2)
    counts = [ nil, 37, 50 ]
    dates.zip(counts).each { |date, capacity| dated_shift(date, "AM", capacity: capacity) }
    dated_shift(dates.last, "NIGHT", capacity: 25)
    set_nights(true)
    assert_published_schedule(dates.zip([ 20, 37, 50 ]).to_h do |date, total|
      [ date, [ shift("AM", "上午", total), (shift("NIGHT", "晚班", 25) if date == dates.last) ].compact ]
    end)

    configure_time_slots
    assert_published_schedule(dates.zip([ 40, 37, 40 ]).to_h do |date, total|
      [ date, [ shift("AM", "上午", total), (shift("NIGHT", "晚班", 25) if date == dates.last) ].compact ]
    end)
    assert_equal [ 5 ] * 8, published_shifts(dates.last).first.fetch("slots").pluck("remaining")
    legacy = published_shifts(@monday + 1, time_slots: false).sole
    assert_equal [ "AM", 37, 0 ], legacy.values_at("time_slot", "total", "remaining")
    assert_not legacy.key?("slots")
    assert response.parsed_body.fetch("schedule").all? { |day| day.fetch("doctors").empty? }
    assert_equal Time.iso8601("2026-12-01T11:30:00+08:00").to_i * 1000, legacy.fetch("cutoff_at")
    get adjustment_page
    assert_select "#adjustment-capacity:not([value])"
    assert_select "#adjustment-capacity-hint", text: "按时段自动计算，共 40 号"
    get admins_doctor_schedule_path(@doctor, tab: "date", date: dates.last.iso8601)
    assert_select "#adjustment-capacity[value='50']"
    assert_select "#adjustment-capacity-hint", text: "按当前时段最多可约 40 人"

    configure_time_slots(max_bookings_per_slot: 4)
    assert_equal [ 32, 25 ], published_shifts(dates.last).pluck("total")
    configure_time_slots(booking_by_time_slot: false, default_capacity: 23)
    assert_equal [ 50, 25 ], published_shifts(dates.last, time_slots: false).pluck("remaining")
    assert_equal 37, published_shifts(@monday + 1, time_slots: false).sole.fetch("remaining")
    day = response.parsed_body.fetch("schedule").find { |entry| entry.fetch("date") == (@monday + 1).iso8601 }
    assert_equal %w[AM], day.fetch("doctors").fetch(@doctor.id.to_s)
    assert_equal 23, published_shifts(@monday, time_slots: false).sole.fetch("remaining")
    assert_equal counts, @doctor.schedules.where(time_slot: "AM").order(:start_date).pluck(:capacity)
  end

  test "the last shift seat can be booked at any open slot and the last slot closes at its start" do
    rule = dated_shift(@monday, "AM", capacity: 37)
    dated_shift(@monday, "NIGHT", capacity: 9)
    set_nights(true)
    other = Doctor.create!(name: "另一位医生", departments: @doctor.departments)
    other.schedules.create!(weekday: @monday.wday, start_date: @monday, time_slot: "AM")
    configure_time_slots
    counts = %w[08:00 08:30 09:00 09:30 10:00 10:30 11:00 11:30].zip([ 5, 5, 4, 5, 4, 5, 4, 4 ]).to_h
    occupancy = { [ @doctor.id, @monday, "AM" ] => counts }
    new_calendar = -> do
      source = ScheduleCalendar.new([ @doctor.id, other.id ], @monday..@monday)
      source.define_singleton_method(:occupied_counts) { occupancy }
      source
    end
    calendar = new_calendar.call
    morning = ->(source) { source.day_availability(@doctor.id, @monday, include_times: true).fetch(:shifts).first }
    bookable = ->(options, now) { options.select { |option| option[:remaining].positive? && option[:cutoff_at] > now.to_i * 1000 } }
    assert_equal 1, morning.call(calendar)[:remaining]
    before = Time.zone.local(2026, 11, 30, 8, 45)
    candidates = bookable.call(morning.call(calendar)[:slots], before)
    assert_equal %w[09:00 10:00 11:00 11:30], candidates.pluck(:start_time)
    assert_equal [ 1 ] * 4, candidates.pluck(:remaining)
    assert_equal [ 1 ] * 4, candidates.pluck(:shift_available)
    candidates.each do |option|
      counts[option[:start_time]] += 1
      assert_empty bookable.call(morning.call(calendar)[:slots], before)
      counts[option[:start_time]] -= 1
    end
    rule.update!(capacity: 35)
    reduced = new_calendar.call
    assert_equal 0, morning.call(reduced).fetch(:remaining)
    assert_equal 0, morning.call(reduced).fetch(:slots).last.fetch(:shift_available)
    assert_equal 9, reduced.day_availability(@doctor.id, @monday).fetch(:shifts).last.fetch(:remaining)
    assert_equal 40, reduced.day_availability(other.id, @monday).fetch(:shifts).sole.fetch(:remaining)
    rule.update!(capacity: 37)

    counts.replace({ "08:00" => 5, "08:30" => 5, "09:00" => 5, "09:30" => 5, "10:00" => 1, "11:30" => 4 })
    morning_shift = morning.call(calendar)
    assert_equal 12, morning_shift[:remaining]
    assert_equal 1, morning_shift[:slots].last.fetch(:shift_available)
    at_1120 = Time.iso8601("2026-11-30T11:20:00+08:00")
    assert_equal [ [ "11:30", "12:00", 1 ] ], bookable.call(morning_shift[:slots], at_1120).map { |slot| slot.values_at(:start_time, :end_time, :remaining) }
    assert_empty bookable.call(morning_shift[:slots], at_1120 + 10.minutes)

    configure_time_slots(booking_by_time_slot: false)
    whole_shift = morning.call(new_calendar.call)
    assert_equal 12, bookable.call([ whole_shift ], at_1120 + 39.minutes).sole[:remaining]
    assert_empty bookable.call([ whole_shift ], at_1120 + 40.minutes)

    counts.replace({ "09:00" => 4 })
    configure_time_slots(max_bookings_per_slot: 3)
    reduced_slots = morning.call(new_calendar.call).fetch(:slots).index_by { |slot| slot.fetch(:start_time) }
    assert_equal [ 0, 3 ], reduced_slots.values_at("09:00", "09:30").pluck(:remaining)
    assert_equal 20, morning.call(new_calendar.call).fetch(:remaining)
  end

  test "both departments use the same adjusted slots and a full day skips the lunch break" do
    configure_time_slots(booking_morning_begin_at: "08:30", booking_afternoon_begin_at: "13:30", booking_afternoon_end_at: "16:30")
    set_nights(true)
    save_weekly(monday_week)
    adjust(time_slot: "PM", capacity: "37", night: "1", night_capacity: "4")
    assert_response :see_other
    dated_shift(@monday + 1, "FULL")

    @doctor.department_ids.each do |department_id|
      get api_mini_program_doctors_path(@mini_program.appid), params: { department_id: department_id }
      assert_response :success
      assert_equal @doctor.id.to_s, response.parsed_body.fetch("doctors").sole.fetch("id")
    end
    adjusted = published_shifts(@monday)
    assert_equal %w[PM NIGHT], adjusted.pluck("time_slot")
    assert_equal [ "13:30", "17:00" ], adjusted.map { |row| row.fetch("slots").first.fetch("start_time") }
    assert_equal %w[AM NIGHT], published_shifts(@monday + 7).pluck("time_slot")
    full = published_shifts(@monday + 1).sole
    assert_equal [ "FULL", 65 ], full.values_at("time_slot", "total")
    assert_equal %w[08:30 09:00 09:30 10:00 10:30 11:00 11:30 13:30 14:00 14:30 15:00 15:30 16:00], full.fetch("slots").pluck("start_time")
    assert_equal Time.iso8601("2026-12-01T16:00:00+08:00").to_i * 1000, full.fetch("cutoff_at")
    set_nights(false)
    assert_equal [ adjusted.first ], published_shifts(@monday)
    set_nights(true)
    assert_equal adjusted, published_shifts(@monday)
    adjust(time_slot: "", night: "0")
    assert_response :see_other
    assert_empty published_shifts(@monday)
    assert_equal %w[AM NIGHT], published_shifts(@monday + 7).pluck("time_slot")
    revoke_adjustment
    assert_response :see_other
    assert_equal %w[AM NIGHT], published_shifts(@monday).pluck("time_slot")
  end

  test "the selected month survives a date adjustment and a weekly save" do
    get admins_doctor_schedule_path(@doctor)
    assert_response :success
    assert_select "nav[aria-label='医生排班'] a" do |tabs|
      assert_equal %w[排班日历 每周排班 指定日期调整], tabs.map(&:text)
    end
    assert_select "a.active[aria-current='page']", text: "排班日历"
    assert_select "#doctor-schedule-calendar[data-initial-date='2026-11-01']"

    month = "2026-12"
    date = "2026-12-07"
    calendar_path = admins_doctor_schedule_path(@doctor, month: month)
    date_path = admins_doctor_schedule_path(@doctor, month: month, tab: "date", date: date)
    assert_select "a[href=?]", calendar_path, text: "下月"
    get calendar_path
    assert_select "#doctor-schedule-calendar[data-adjustment-url=?]", admins_doctor_schedule_path(@doctor, month: month, tab: "date")

    assert_no_difference [ "Schedule.count", "Log.where(category: 'booking').count" ] do
      get date_path
      assert_response :success
    end
    assert_select "#date-adjustment-editor input[name='month'][value=?]", month
    assert_select "#date-adjustment-editor input[name='date'][value=?]", date
    assert_select "#adjustment-time-slot option[selected][value='']"
    assert_select "script[src*='fullcalendar']", count: 0

    patch date_adjustment_admins_doctor_schedule_path(@doctor), params: {
      month: month, date: date, revision: date_form_revision, date_adjustment: { time_slot: "AM", capacity: "5" }
    }
    assert_redirected_to date_path
    follow_redirect!
    assert_select "a[href=?]", calendar_path, text: "排班日历"

    patch weekly_admins_doctor_schedule_path(@doctor), params: {
      month: month, revision: schedule_editor.weekly_revision, weekly_schedule: { "1" => { time_slot: "PM" } }
    }
    assert_redirected_to admins_doctor_schedule_path(@doctor, month: month, tab: "weekly")
    follow_redirect!
    assert_select "a.active[aria-current='page']", text: "每周排班"
  end

  test "a whole date adjustment replaces the week and clearing survives until it is revoked" do
    get admins_doctor_path(@doctor)
    assert_select "a[href=?]", admins_doctor_schedule_path(@doctor), text: "排班"
    save_weekly({ "1" => { time_slot: "AM", capacity: "" } })
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
    patch admins_system_settings_appointment_path, params: {
      appointment: { revision: AppointmentSettings.new.revision, require_mobile_auth: "0", booking_enable_evening: "1" }
    }
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
    [ true, false, true ].each do |enabled|
      set_nights(enabled)
      assert_off
    end
    revoke_adjustment
    assert_redirected_to adjustment_page
    assert_empty @doctor.schedules.on_date(@monday)
    assert_published_schedule({ @monday => [ shift("AM", "上午") ] })

    events = Log.operations_visible_to(@operator).where(action: %w[schedule.create schedule.update schedule.revoke]).order(:id)
    assert_equal %w[schedule.create schedule.create schedule.update schedule.update schedule.update schedule.update schedule.revoke], events.pluck(:action)
    revoke = events.last
    assert_equal [ "success", "Schedule", @doctor.id, @monday.iso8601 ],
      [ revoke.status, revoke.target_type, *revoke.details.values_at("doctor_id", "schedule_date") ]
    get admins_operation_log_path(revoke)
    assert_response :success
    assert_select "dd", text: @monday.iso8601
  end

  test "stale weekly forms show current values and cannot overwrite the latest published shifts" do
    first_week = { "1" => { time_slot: "AM", capacity: "20" }, "2" => { time_slot: "AM", capacity: "12" } }
    save_weekly(first_week)
    get admins_doctor_schedule_path(@doctor, tab: "weekly")
    original = weekly_form_revision
    monday_changed = first_week.merge("1" => { time_slot: "AM", capacity: "37" })
    tuesday_changed = { "2" => { time_slot: "AM", capacity: "8" } }

    invalid = first_week.merge("2" => { time_slot: "AM", capacity: "0" })
    save_weekly(invalid, revision: original, status: :unprocessable_content)
    assert_equal original, weekly_form_revision
    save_weekly(monday_changed, revision: original)
    save_weekly(first_week.merge(tuesday_changed), revision: original, status: :conflict)
    assert_select "[role=alert]", text: /排班已被修改/
    assert_select "#weekday-1-capacity[value='37']"
    assert_select "#weekday-2-capacity[value='12']"
    fresh = weekly_form_revision
    assert_not_equal original, fresh
    save_weekly(monday_changed.merge(tuesday_changed), revision: fresh)

    save_weekly(first_week.merge("1" => { time_slot: "AM", capacity: "30" }), revision: fresh, status: :conflict)
    save_weekly(first_week, revision: nil, status: :conflict)
    assert_equal [ 37, 8 ], [ @monday, @monday + 1 ].map { |date| published_shifts(date).sole.fetch("total") }
  end

  test "an outdated date adjustment form cannot save or revoke another operator's new entry" do
    dated_shift(@monday, "PM", capacity: 18)
    get adjustment_page
    original = date_form_revision
    assert_equal original, assert_select("#revoke-date-adjustment input[name='revision']").sole["value"]
    adjust(revision: original, time_slot: "PM", capacity: "22")
    assert_response :see_other

    adjust(revision: original, time_slot: "AM", capacity: "12")
    assert_response :conflict
    assert_select "#adjustment-capacity[value='22']"
    revoke_adjustment(revision: original)
    assert_response :conflict
    assert_select "[role=alert]", text: /排班已被修改/
    fresh = date_form_revision
    assert_equal [ "PM", 22 ], published_shifts(@monday).sole.values_at("time_slot", "total")

    revoke_adjustment(revision: fresh)
    assert_response :see_other
    assert_empty published_shifts(@monday)
  end

  test "the configuration clock and the fourteen-day window change together at Beijing midnight" do
    future_date = Date.new(2026, 12, 14)
    dated_shift(future_date, "AM")
    path = api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    midnight = Time.zone.local(2026, 12, 1)
    [ midnight - 1.second, midnight ].each do |now|
      travel_to now
      get path, params: { schedule_format: "time_slots" }
      assert_response :success
      config = response.parsed_body
      assert_equal [ now.to_i * 1000, (now.to_date + 1).in_time_zone.to_i * 1000 ], config.values_at("server_time", "schedule_refresh_at")
      assert_equal now.to_date..(now.to_date + 13), Date.iso8601(config.fetch("schedule").first.fetch("date"))..Date.iso8601(config.fetch("schedule").last.fetch("date"))
      assert_equal now == midnight ? [ "AM" ] : [], config.fetch("schedule").last.fetch("doctors").fetch(@doctor.id.to_s, [])
    end
  end

  test "customer service can read either form but cannot save or revoke an adjustment" do
    adjust(time_slot: "FULL")
    assert_response :see_other
    customer_service = Admin.create!(username: "schedule_customer_service", role: "customer_service")
    sign_in customer_service

    get admins_doctor_schedule_path(@doctor)
    assert_response :success
    assert_select "#doctor-schedule-calendar"
    get admins_doctor_schedule_path(@doctor, tab: "weekly")
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
      revoke_adjustment
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

  test "invalid date lookups show feedback beside the date field" do
    invalid_date = "2026-11-31"
    get admins_doctor_schedule_path(@doctor, tab: "date", date: invalid_date)

    assert_response :unprocessable_content
    assert_select "#schedule-date.is-invalid[aria-describedby='schedule-date-error'][value=?]", invalid_date
    assert_select "#schedule-date-error.d-block", text: /请输入有效日期/
    assert_select "#date-adjustment-editor button[type='submit'][disabled]"

    assert_no_difference "Schedule.count" do
      patch date_adjustment_admins_doctor_schedule_path(@doctor), params: {
        date: invalid_date, date_adjustment: { time_slot: "AM" }
      }
      assert_response :bad_request
    end
  end

  test "pausing nights and saving weekly daytime shifts preserves counted and blank nights" do
    set_nights(true)
    save_weekly(monday_week.merge("2" => { time_slot: "", night: "1", night_capacity: "" }))
    tuesday = @monday + 1
    regular = { @monday => [ shift("AM", "上午", 8), shift("NIGHT", "晚班", 4) ], tuesday => [ shift("NIGHT", "晚班") ] }

    set_nights(false)
    get admins_doctor_schedule_path(@doctor, tab: "weekly")
    assert_select "form[action=?] input[name$='[night]']", weekly_admins_doctor_schedule_path(@doctor), count: 0
    assert_published_schedule({ @monday => [ shift("AM", "上午", 8) ], tuesday => [] })
    set_nights(true)
    assert_published_schedule(regular)

    set_nights(false)
    save_weekly({ "1" => { time_slot: "PM", capacity: "5" }, "2" => { time_slot: "" } })
    set_nights(true)
    assert_published_schedule(regular.merge(@monday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 4) ]))
  end

  test "a daytime-only date adjustment keeps the applicable weekly night on just that date" do
    set_nights(true)
    save_weekly(monday_week)

    set_nights(false)
    get adjustment_page
    assert_select "#adjustment-time-slot option[selected][value='AM']"
    assert_select "#date-adjustment-editor input[name='date_adjustment[night]']", count: 0
    adjust(time_slot: "PM", capacity: "5")
    assert_response :see_other
    set_nights(true)

    assert_published_schedule({ @monday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 4) ],
      (@monday + 7) => [ shift("AM", "上午", 8), shift("NIGHT", "晚班", 4) ] })
  end

  test "daytime edits follow each date adjustment's own night shift decision" do
    set_nights(true)
    save_weekly(monday_week)
    second_monday = @monday + 7
    adjust(time_slot: "AM", capacity: "8", night: "1", night_capacity: "2")
    assert_response :see_other
    adjust(date: second_monday, time_slot: "AM", capacity: "8", night: "0")
    assert_response :see_other

    set_nights(false)
    [ @monday, second_monday ].each do |date|
      adjust(date: date, time_slot: "PM", capacity: "5")
      assert_response :see_other
    end
    set_nights(true)

    assert_published_schedule({ @monday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 2) ],
      second_monday => [ shift("PM", "下午", 5) ] })
  end

  test "with nights paused a blank daytime selection keeps weekly and specified nights" do
    set_nights(true)
    save_weekly({ "1" => { time_slot: "", night: "1", night_capacity: "4" },
      "2" => { time_slot: "AM", capacity: "8", night: "1", night_capacity: "3" } })
    specified_date = @monday + 7
    adjust(date: specified_date, time_slot: "", night: "1", night_capacity: "2")
    assert_response :see_other

    set_nights(false)
    tuesday = @monday + 1
    assert_published_schedule({ @monday => [], specified_date => [], tuesday => [ shift("AM", "上午", 8) ] })
    [ @monday, specified_date, tuesday ].each do |date|
      adjust(date: date, time_slot: "")
      assert_response :see_other
    end
    assert_empty @doctor.schedules.on_date(@monday)
    set_nights(true)

    assert_published_schedule({ @monday => [ shift("NIGHT", "晚班", 4) ], specified_date => [ shift("NIGHT", "晚班", 2) ],
      tuesday => [ shift("NIGHT", "晚班", 3) ] })
  end

  [ true, false ].each do |night_enabled|
    test "an empty date saved with nights #{night_enabled ? 'enabled' : 'paused'} stays off when the week gains a shift" do
      set_nights(night_enabled)
      get adjustment_page
      assert_response :success
      assert_select "#adjustment-time-slot option[selected][value='']"
      assert_select "#adjustment-night", count: night_enabled ? 1 : 0

      fields = night_enabled ? { time_slot: "", night: "0" } : { time_slot: "" }
      adjust(**fields)
      assert_response :see_other
      assert_equal [ [ "OFF", nil ] ], @doctor.schedules.on_date(@monday).pluck(:time_slot, :capacity)

      save_weekly({ "1" => { time_slot: "AM", capacity: "8" } })
      morning = [ shift("AM", "上午", 8) ]
      assert_published_schedule({ @monday => [], (@monday + 7) => morning }, closed: [ @monday ])

      revoke_adjustment
      assert_redirected_to adjustment_page
      assert_empty @doctor.schedules.on_date(@monday)
      assert_published_schedule({ @monday => morning })
    end
  end

  test "stale daytime-only forms preserve nights and stale night edits fail atomically" do
    set_nights(true)
    save_weekly(monday_week.merge("2" => { time_slot: "AM", capacity: "6", night: "1", night_capacity: "3" }))

    set_nights(false)
    [ admins_doctor_schedule_path(@doctor, tab: "weekly"), adjustment_page ].each do |path|
      get path
      assert_select "input[name$='[night]']", count: 0
    end
    set_nights(true)

    save_weekly({ "1" => { time_slot: "AM", capacity: "8" }, "2" => { time_slot: "PM", capacity: "5" } })
    adjust(time_slot: "PM", capacity: "5")
    assert_response :see_other
    tuesday = @monday + 1
    assert_published_schedule({ @monday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 4) ],
      tuesday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 3) ] })

    [ admins_doctor_schedule_path(@doctor, tab: "weekly"), adjustment_page ].each do |path|
      get path
      assert_select "input[name$='[night]'][type='checkbox']"
    end
    set_nights(false)
    previous = @doctor.schedules.order(:id).pluck(:id, :time_slot, :capacity)
    save_weekly({ "1" => { time_slot: "AM", capacity: "9", night: "0" },
      "3" => { time_slot: "AM", capacity: "2", night: "1", night_capacity: "6" } }, status: :unprocessable_content)
    assert_select ".alert-danger", text: /请刷新页面/
    adjust(time_slot: "AM", capacity: "9", night: "1", night_capacity: "6")
    assert_response :unprocessable_content
    assert_select ".alert-danger", text: /请刷新页面/
    assert_equal previous, @doctor.schedules.order(:id).pluck(:id, :time_slot, :capacity)
    set_nights(true)

    assert_published_schedule({ @monday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 4) ],
      tuesday => [ shift("PM", "下午", 5), shift("NIGHT", "晚班", 3) ] })
  end

  private

  def exported_rows
    xml = Zip::File.open_buffer(response.body).read("xl/worksheets/sheet1.xml")
    Nokogiri::XML(xml).remove_namespaces!.xpath("//sheetData/row").map do |row|
      cells = row.xpath("c").to_h { |cell| [ cell["r"].delete("0-9"), cell.at_xpath("v|is/t")&.text ] }
      cells.values_at("A", "B", "C", "D", "E")
    end
  end

  def shift(slot, label, total = 20)
    { "time_slot" => slot, "label" => label, "total" => total, "remaining" => total }
  end

  def set_nights(enabled)
    setting = Setting.find_or_initialize_by(key: "appointment")
    setting.write_value(Schedule::NIGHT_SETTING, enabled)
    setting.save!
  end

  def configure_time_slots(**fields)
    setting = Setting.find_or_initialize_by(key: "appointment")
    { booking_by_time_slot: true, **fields }.each { |field, value| setting.write_value(field.to_s, value) }
    setting.save!
  end

  def published_shifts(date, time_slots: true)
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid), params: (time_slots ? { schedule_format: "time_slots" } : {})
    assert_response :success
    days = response.parsed_body.fetch("schedule").index_by { |day| day.fetch("date") }
    days.fetch(date.iso8601).fetch("availability").fetch(@doctor.id.to_s, [])
  end

  def monday_week = { "1" => { time_slot: "AM", capacity: "8", night: "1", night_capacity: "4" } }

  def schedule_editor = ScheduleEditor.new(doctor: @doctor, actor: @operator, request: nil)

  def weekly_form_revision = assert_select("form input[name='revision']").sole["value"]

  def date_form_revision = assert_select("#date-adjustment-editor input[name='revision']").sole["value"]

  def save_weekly(week, status: :see_other, revision: schedule_editor.weekly_revision)
    patch weekly_admins_doctor_schedule_path(@doctor), params: { weekly_schedule: week, revision: revision }
    assert_response status
  end

  def adjustment_page = admins_doctor_schedule_path(@doctor, tab: "date", date: @monday.iso8601, month: @monday.strftime("%Y-%m"))

  def dated_shift(date, slot, capacity: nil)
    @doctor.schedules.create!(weekday: date.wday, start_date: date, end_date: date, time_slot: slot, capacity: capacity)
  end

  def calendar_days(month)
    get admins_doctor_schedule_path(@doctor, month: month)
    assert_response :success
    JSON.parse(assert_select("#doctor-schedule-calendar").sole["data-days"]).tap do |days|
      days.each_value do |day|
        day.fetch("shifts").each { |shift| shift.except!("cutoff_at", "start_time", "end_time", "slots") }
      end
    end
  end

  def adjust(date: @monday, revision: schedule_editor.date_revision(date), **fields)
    patch date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: date.iso8601, date_adjustment: fields, revision: revision }
  end

  def revoke_adjustment(revision: schedule_editor.date_revision(@monday))
    delete date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: @monday.iso8601, revision: revision }
  end

  def assert_published_schedule(expected, closed: [])
    expected.group_by { |date, _| date.strftime("%Y-%m") }.each do |month, entries|
      days = calendar_days(month)
      entries.each do |date, shifts|
        day = days.fetch(date.iso8601)
        assert_equal shifts, day.fetch("shifts"), date.iso8601
        assert_equal closed.include?(date), day.fetch("off"), date.iso8601
      end
    end

    get api_app_configuration_path(@mini_program.provider, @mini_program.appid), params: { schedule_format: "time_slots" }
    assert_response :success
    days = response.parsed_body.fetch("schedule").index_by { |day| day.fetch("date") }
    expected.each do |date, shifts|
      day = days.fetch(date.iso8601)
      published = day.fetch("availability").fetch(@doctor.id.to_s, [])
      assert_equal shifts, published.map { |shift| shift.except("cutoff_at", "start_time", "end_time", "slots") }, date.iso8601
      published.each do |shift|
        hour = { "AM" => 12, "PM" => 17, "FULL" => 17, "NIGHT" => 21 }.fetch(shift.fetch("time_slot"))
        cutoff = Time.new(date.year, date.month, date.day, hour, 0, 0, "+08:00")
        cutoff -= 30.minutes if shift.key?("slots")
        assert_equal cutoff.to_i * 1000, shift.fetch("cutoff_at")
      end
      assert_equal shifts.pluck("time_slot"), day.fetch("doctors").fetch(@doctor.id.to_s, []), date.iso8601
    end
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
    assert_published_schedule({ @monday => [], (@monday + 7) => [ shift("AM", "上午") ] }, closed: [ @monday ])
  end
end

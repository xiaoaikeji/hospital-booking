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
    assert_equal [ shift("FULL", "全天") ], days.fetch("2026-12-22").fetch("shifts")
    assert_equal({ "adjusted" => true, "off" => false, "shifts" => [ shift("PM", "下午", 60), shift("NIGHT", "晚班", 20) ] }, days.fetch("2026-12-21"))
    assert_equal({ "adjusted" => true, "off" => true, "shifts" => [] }, days.fetch("2026-12-23"))
    assert_equal [ shift("NIGHT", "晚班", 30) ], days.fetch("2026-12-24").fetch("shifts")
    assert_equal({ "adjusted" => false, "off" => false, "shifts" => [] }, days.fetch("2026-12-25"))

    set_nights(false)
    days = calendar_days("2026-12")
    assert_equal [ shift("PM", "下午", 60) ], days.fetch("2026-12-21").fetch("shifts")
    assert_equal({ "adjusted" => true, "off" => false, "shifts" => [] }, days.fetch("2026-12-24"))
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
        [ date, @doctor.name, @doctor.department_names, shift.fetch("label"), shift["total"]&.to_s ]
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

  test "both calendars share availability by doctor and shift and keep blank capacity distinct from full" do
    set_nights(true)
    dated_shift(@monday, "FULL", capacity: 20)
    dated_shift(@monday, "NIGHT", capacity: 5)
    blank_date = @monday - 1
    dated_shift(blank_date, "FULL")

    admin_days = calendar_days("2026-11")
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_response :success
    published = response.parsed_body
    assert_equal @doctor.department_ids.map(&:to_s).sort, published.dig("directory", "doctors").sole.fetch("department_ids").sort
    mini_days = published.fetch("schedule").index_by { |day| day.fetch("date") }
    [ @monday, blank_date ].each do |date|
      assert_equal admin_days.dig(date.iso8601, "shifts"), mini_days.dig(date.iso8601, "availability", @doctor.id.to_s)
    end
    assert_equal [ shift("FULL", "全天", 20), shift("NIGHT", "晚班", 5) ], admin_days.dig(@monday.iso8601, "shifts")
    assert_equal [ shift("FULL", "全天") ], admin_days.dig(blank_date.iso8601, "shifts")

    counts = { [ @doctor.id, @monday, "FULL" ] => 7, [ @doctor.id, @monday, "NIGHT" ] => 6 }
    calendar = ScheduleCalendar.new([ @doctor.id ], blank_date..@monday)
    calendar.define_singleton_method(:occupied_counts) { counts }
    assert_equal [ [ 20, 13 ], [ 5, 0 ] ], calendar.day_availability(@doctor.id, @monday).fetch(:shifts).map { |row| row.values_at(:total, :remaining) }
    assert_nil calendar.day_availability(@doctor.id, blank_date).fetch(:shifts).sole.fetch(:remaining)
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
      month: month, date: date, date_adjustment: { time_slot: "AM", capacity: "5" }
    }
    assert_redirected_to date_path
    follow_redirect!
    assert_select "a[href=?]", calendar_path, text: "排班日历"

    patch weekly_admins_doctor_schedule_path(@doctor), params: {
      month: month, weekly_schedule: { "1" => { time_slot: "PM" } }
    }
    assert_redirected_to admins_doctor_schedule_path(@doctor, month: month, tab: "weekly")
    follow_redirect!
    assert_select "a.active[aria-current='page']", text: "每周排班"
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
    delete date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: @monday.iso8601 }
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

      delete date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: @monday.iso8601 }
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

  def shift(slot, label, total = nil)
    { "time_slot" => slot, "label" => label, "total" => total, "remaining" => total }
  end

  def set_nights(enabled)
    setting = Setting.find_or_initialize_by(key: "appointment")
    setting.write_value(Schedule::NIGHT_SETTING, enabled)
    setting.save!
  end

  def monday_week = { "1" => { time_slot: "AM", capacity: "8", night: "1", night_capacity: "4" } }

  def save_weekly(week, status: :see_other)
    patch weekly_admins_doctor_schedule_path(@doctor), params: { weekly_schedule: week }
    assert_response status
  end

  def adjustment_page = admins_doctor_schedule_path(@doctor, tab: "date", date: @monday.iso8601, month: @monday.strftime("%Y-%m"))

  def dated_shift(date, slot, capacity: nil)
    @doctor.schedules.create!(weekday: date.wday, start_date: date, end_date: date, time_slot: slot, capacity: capacity)
  end

  def calendar_days(month)
    get admins_doctor_schedule_path(@doctor, month: month)
    assert_response :success
    JSON.parse(assert_select("#doctor-schedule-calendar").sole["data-days"])
  end

  def adjust(date: @monday, **fields)
    patch date_adjustment_admins_doctor_schedule_path(@doctor), params: { date: date.iso8601, date_adjustment: fields }
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

    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_response :success
    days = response.parsed_body.fetch("schedule").index_by { |day| day.fetch("date") }
    expected.each do |date, shifts|
      day = days.fetch(date.iso8601)
      assert_equal shifts, day.fetch("availability").fetch(@doctor.id.to_s, []), date.iso8601
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

require "test_helper"
require_relative "../support/wechat_pay_protocol"

class MiniProgramAppointmentRacesTest < ActionDispatch::IntegrationTest
  include Rails.application.routes.url_helpers
  include WechatPayProtocol

  self.use_transactional_tests = false

  setup do
    @day = Date.current + 1
    @mini_program = App.create!(provider: "wechat", status: "active", appid: "race-#{SecureRandom.hex(8)}")
    @departments = %w[并发全科 并发门诊].map { |name| Department.create!(name: name) }
    @doctors = %w[并发甲医生 并发乙医生].map do |name|
      Doctor.create!(name: name, departments: @departments).tap do |doctor|
        doctor.schedules.create!(weekday: @day.wday, start_date: @day, time_slot: "AM", capacity: 20)
      end
    end
    @users = Array.new(2) { User.create!(platform: "wechat") }
    @clients = @users.map { |user| client_for(user, @mini_program) }
  end

  teardown do
    if @payment_profile_ids
      Setting.where("key LIKE 'wechat_pay%'").where.not(id: @payment_profile_ids).delete_all
      Setting.find_by!(key: "wechat_pay").update!(settings: @payment_profile_settings) if @payment_profile_settings
    end
    user_ids = @users&.map(&:id)
    if user_ids
      Log.where(actor_type: "User", actor_id: user_ids).delete_all
      Appointment.where(user_id: user_ids).delete_all
      Patient.where(user_id: user_ids).delete_all
      UserApp.where(user_id: user_ids).delete_all
      User.where(id: user_ids).delete_all
    end
    @doctors&.each do |doctor|
      Schedule.where(doctor: doctor).delete_all
      DoctorDepartment.where(doctor: doctor).delete_all
      doctor.destroy!
    end
    @departments&.each(&:destroy!)
    @second_program&.destroy!
    @mini_program&.destroy!
  end

  test "different accounts and departments share the last paid seat" do
    enable_paid_bookings
    @doctors.first.schedules.sole.update!(capacity: 1)
    results = race([ 0, draft(department_id: @departments.first.id) ], [ 1, draft(department_id: @departments.last.id) ])
    assert_equal [ 201, 422 ], results.map(&:first).sort
    assert_equal "slot_full", results.find { |status, _body| status == 422 }.last.fetch("code")
    appointment = Appointment.where(doctor: @doctors.first, appointment_date: @day).sole
    assert_equal [ "pending_payment", 2000, 0 ], appointment.attributes.values_at("status", "payable_amount_cents", "paid_amount_cents")
    calendar = ScheduleCalendar.new([ @doctors.first.id ], @day..@day)
    assert_equal 0, calendar.day_availability(@doctors.first.id, @day).fetch(:shifts).sole.fetch(:remaining)
  end

  test "two concurrent submissions after five appointments on the same visit date leave exactly six" do
    enable_paid_bookings
    @second_program = App.create!(provider: "wechat", status: "active", appid: "race-#{SecureRandom.hex(8)}")
    @clients << client_for(@users.first, @second_program)
    5.times do |index|
      assert_equal 201, request_booking(0, draft(patient_name: "并发示例家属#{index}")).first
    end
    results = race([ 0, draft(patient_name: "并发示例家属甲") ],
      [ 2, draft(doctor_id: @doctors.last.id, department_id: @departments.last.id, patient_name: "并发示例家属乙") ])
    assert_equal [ 201, 422 ], results.map(&:first).sort
    assert_equal "daily_limit", results.find { |status, _body| status == 422 }.last.fetch("code")
    assert_equal 6, @users.first.appointments.where(appointment_date: @day).count
  end

  private

  def enable_paid_bookings
    @payment_profile_ids = Setting.where("key LIKE 'wechat_pay%'").ids
    @payment_profile_settings = Setting.find_by(key: "wechat_pay")&.settings
    @doctors.first.update!(fee: 20)
    generate_payment_keys
    settings = WechatPaySettings.new
    assert settings.save(payment_settings("v3").merge("revision" => settings.revision), actor: nil)
  end

  def draft(**fields)
    {
      doctor_id: @doctors.first.id, department_id: @departments.first.id, date: @day.iso8601,
      time_slot: "AM", mode: "shift", start_time: "08:00", end_time: "12:00", idempotency_key: SecureRandom.uuid,
      patient_name: "并发示例就诊人", patient_gender: 1, patient_age: 40, patient_mobile: "10000000003"
    }.merge(fields)
  end

  def client_for(user, app)
    identity = user.user_apps.create!(app: app, openid: "fixture-#{user.id}", last_sign_in_at: Time.current)
    [ api_mini_program_appointments_path(app.appid), { "Authorization" => "Bearer #{MiniProgramSession.issue!(identity).fetch(:token)}" } ]
  end

  def request_booking(client_index, payload)
    path, headers = @clients.fetch(client_index)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post(path, params: { appointment: payload }, headers: headers, as: :json)
    [ session.response.status, session.response.parsed_body ]
  end

  def race(*bookings)
    ready = Queue.new
    start = Queue.new
    workers = bookings.map do |booking|
      Thread.new do
        ready << true
        start.pop
        request_booking(*booking)
      end
    end
    workers.size.times { ready.pop }
    workers.size.times { start << true }
    workers.map(&:value)
  end
end

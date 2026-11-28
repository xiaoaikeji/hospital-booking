module Appointments
  class Create
    DAILY_LIMIT = 6
    KEY_FORMAT = /\A[\w-]{16,64}\z/
    MESSAGES = {
      invalid_request: "请重新确认预约资料",
      invalid_patient: "请核对就诊人姓名、性别和年龄",
      patient_not_found: "未找到该就诊人，请重新选择",
      department_unavailable: "请选择该医生当前出诊的科室",
      selection_changed: "所选时段已变更，请重新选择",
      slot_closed: "该时段已截止，请重新选择",
      slot_full: "该时段已约满，请重新选择",
      symptoms_required: "请填写症状描述",
      phone_required: "请先验证账号手机号",
      invalid_contact: "请输入有效的本次联系电话",
      daily_limit: "当天预约已达上限（6 笔）",
      same_name: "这个时段已有同名就诊人的预约，是否继续？"
    }.freeze

    class Rejected < StandardError
      attr_reader :code

      def initialize(code, **values)
        @code = code
        super(MESSAGES.fetch(code) % values)
      end
    end

    Result = Data.define(:appointment, :outcome)

    def initialize(user:, app:, identity:, attributes:)
      @user = user
      @app = app
      @identity = identity
      @input = attributes
    end

    # The caller holds the account lock. Schedule and directory writers also
    # lock the doctor, so the availability read and insert see one schedule.
    def call
      key = @input["idempotency_key"].to_s
      reject!(:invalid_request) unless KEY_FORMAT.match?(key)
      if (previous = @user.appointments.find_by(idempotency_key: key))
        return Result.new(previous, "replayed")
      end

      read_selection
      patient = find_patient
      if patient && (previous = matching_bookings.find_by(patient: patient))
        return Result.new(previous, "already_booked")
      end

      doctor = Doctor.current.enabled.lock.find_by(id: @doctor_id)
      reject!(:selection_changed) unless doctor
      department = doctor.departments.find_by(id: parse_id(@input["department_id"]))
      reject!(:department_unavailable) unless department&.visible_in_booking?
      reject!(:daily_limit) if @user.appointments.current.occupying.where(appointment_date: @date).count >= DAILY_LIMIT

      profile = patient || Patient.new(user: @user, name: @input["patient_name"], gender: @input["patient_gender"], age: @input["patient_age"])
      reject!(:invalid_patient) unless profile.valid?
      settings = AppointmentSettings.new(lock: "FOR SHARE")
      remark = @input["remark"].to_s.strip.presence
      contact = @input["patient_mobile"].to_s.strip.delete(" -")
      hospital = HospitalProfile.new.public_values.slice("company_name", "address", *HospitalProfile::COORDINATE_FIELDS.keys)
      calendar = ScheduleCalendar.new([ doctor.id ], @date..@date, settings: settings)
      same_name = !patient && @input["confirm_same_name"] != true && matching_bookings.exists?(patient_name: profile.name)

      appointment = SavePatientOnCreation.call(user: @user, save_patient: @input["save_patient"]) do
        result = calendar.check_selection(doctor.id, @date, **@selection)
        reject!(result) unless result == :bookable
        reject!(:symptoms_required) if settings.enabled?("require_booking_remark") && remark.nil?
        reject!(:phone_required) if PhoneVerification.required_for?(@user, settings: settings)
        reject!(:invalid_contact) unless /\A\+?[0-9]{6,15}\z/.match?(contact)
        reject!(:same_name) if same_name

        fee = (doctor.fee * 100).to_i
        payment = Payments.new.prepare(app: @app, identity: @identity, payment_no: Appointment.generate_order_no, amount_cents: fee) if fee.positive?
        # Reserving the payment profile can wait on a configuration write.
        if payment
          result = calendar.check_selection(doctor.id, @date, **@selection)
          reject!(result) unless result == :bookable
        end
        record = @user.appointments.create!(
          order_no: Appointment.generate_order_no, idempotency_key: key,
          doctor: doctor, department: department, patient: patient,
          source_platform: @app.provider, source_appid: @app.appid,
          appointment_date: @date, time_slot: @selection.fetch(:time_slot),
          slot_label: slot_label, booking_start_at: @starts_at, booking_end_at: @ends_at,
          doctor_name: doctor.name, department_name: department.name, hospital_snapshot: hospital,
          patient_name: profile.name, patient_gender: profile.gender, patient_age: profile.age,
          patient_mobile: contact, remark: remark,
          fee_cents: fee, payable_amount_cents: fee, **payment_attributes(payment)
        )
        GroupNotice.publish("appointment_confirmed", record) if record.status == "confirmed"
        [ record, true ]
      end
      Result.new(appointment, "created")
    end

    private

    def payment_attributes(payment)
      return { status: "confirmed", payment_channel: "none", payment_status: "paid" } unless payment

      created = Time.current.change(usec: 0)
      {
        status: "pending_payment", payment_status: "unpaid", payment_channel: "wechat_jsapi",
        payment_platform: @app.provider, payment_appid: @app.appid, payer_user: @user,
        payment_no: payment.fetch("payment_no"), mch_id: payment.fetch("merchant_id"),
        created_at: created, payment_expires_at: created + 30.minutes,
        payment_data: payment.except("payment_no", "merchant_id", "appid", "amount_cents")
      }
    end

    def read_selection
      @doctor_id = parse_id(@input["doctor_id"])
      @date = parse_date(@input["date"])
      @selection = @input.slice("time_slot", "mode", "start_time", "end_time").symbolize_keys
      shift, mode, start_time, end_time = @selection.values_at(:time_slot, :mode, :start_time, :end_time)
      start_index, end_index = [ start_time, end_time ].map { |time| AppointmentSettings::SLOT_TIMES.index(time) }
      unless @doctor_id && @date && ScheduleCalendar::SHIFT_LABELS.key?(shift) && %w[shift slot].include?(mode) &&
          start_index && end_index && start_index < end_index
        reject!(:invalid_request)
      end
      return unless mode == "slot"
      reject!(:invalid_request) unless end_index == start_index + 1

      @starts_at = @date.in_time_zone + start_index * AppointmentSettings::SLOT_MINUTES.minutes
      @ends_at = @date.in_time_zone + end_index * AppointmentSettings::SLOT_MINUTES.minutes
    end

    def parse_id(value)
      id = value.to_s
      id.to_i if /\A[1-9][0-9]{0,18}\z/.match?(id) && id.to_i <= 2**63 - 1
    end

    def parse_date(value)
      date = Date.iso8601(value) if /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/.match?(value.to_s)
      date if date&.year&.positive?
    rescue Date::Error
      nil
    end

    def find_patient
      return if @input["patient_id"].blank?

      @user.patients.find_by(id: parse_id(@input["patient_id"])) || reject!(:patient_not_found)
    end

    def matching_bookings
      bookings = @user.appointments.current.occupying.where(doctor_id: @doctor_id, appointment_date: @date)
      if @starts_at
        bookings.where(booking_start_at: @starts_at, booking_end_at: @ends_at)
      else
        bookings.where(booking_start_at: nil, time_slot: @selection.fetch(:time_slot))
      end
    end

    def slot_label
      start_time, end_time = @selection.values_at(:start_time, :end_time)
      range = "#{start_time}–#{end_time}"
      return range if @starts_at

      "#{ScheduleCalendar::SHIFT_LABELS.fetch(@selection.fetch(:time_slot))} #{range}"
    end

    def reject!(code, **values)
      raise Rejected.new(code, **values)
    end
  end
end

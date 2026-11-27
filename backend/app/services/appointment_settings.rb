class AppointmentSettings
  include ActiveModel::Model

  PHONE_FIELD = "require_mobile_auth"
  PUBLIC_SWITCH_DEFAULTS = {
    "show_unscheduled_doctors" => true,
    "require_booking_remark" => false,
    "display_free_fee_when_fee_is_zero" => true,
    "display_hospital_address" => false
  }.freeze
  TIME_SLOT_FIELD = "booking_by_time_slot"
  SWITCH_DEFAULTS = { PHONE_FIELD => false, Schedule::NIGHT_SETTING => false, TIME_SLOT_FIELD => false, **PUBLIC_SWITCH_DEFAULTS }.freeze
  NOTICE_FIELD = "booking_notice"
  CAPACITY_FIELD = "default_capacity"
  SLOT_CAPACITY_FIELD = "max_bookings_per_slot"
  DEFAULT_CAPACITY = 20
  DEFAULT_SLOT_CAPACITY = 5
  SLOT_MINUTES = 30
  SLOT_TIMES = (0..(24 * 60 / SLOT_MINUTES)).map do |index|
    hour, minute = (index * SLOT_MINUTES).divmod(60)
    format("%02d:%02d", hour, minute)
  end.freeze
  SHIFT_TIME_DEFAULTS = {
    "AM" => { "booking_morning_begin_at" => "08:00", "booking_morning_end_at" => "12:00" }.freeze,
    "PM" => { "booking_afternoon_begin_at" => "12:00", "booking_afternoon_end_at" => "17:00" }.freeze,
    "NIGHT" => { "booking_evening_begin_at" => "17:00", "booking_evening_end_at" => "21:00" }.freeze
  }.freeze
  TIME_DEFAULTS = {}.merge(*SHIFT_TIME_DEFAULTS.values).freeze
  FIELDS = [ *SWITCH_DEFAULTS.keys, NOTICE_FIELD, CAPACITY_FIELD, SLOT_CAPACITY_FIELD, *TIME_DEFAULTS.keys ].freeze
  STALE = "配置已变化，请核对当前设置后再保存"
  INVALID = "预约规则开关无效，请核对后再保存"
  INVALID_CAPACITY = "默认放号数必须为 1 到 2147483647 的整数"
  INVALID_SLOT_CAPACITY = "每 30 分钟最多可约人数必须为 1 到 2147483647 的整数"
  INVALID_TIME = "班次时间只能选择整点或半点"
  INVALID_WINDOW = "班次开始时间必须早于结束时间"
  OVERLAPPING_WINDOWS = "上午、下午和晚班须按顺序设置，班次时间不能重叠"
  FAILURE = "预约设置未保存，请重试"

  class Invalid < StandardError; end

  def initialize
    @record = Setting.find_by(key: "appointment")
  end

  def phone_required? = enabled?(PHONE_FIELD)
  def night_enabled? = enabled?(Schedule::NIGHT_SETTING)
  def time_slot_booking? = enabled?(TIME_SLOT_FIELD)
  def booking_notice = value(NOTICE_FIELD)
  def default_capacity = parse_capacity(value(CAPACITY_FIELD)) || DEFAULT_CAPACITY
  def max_bookings_per_slot = parse_capacity(value(SLOT_CAPACITY_FIELD)) || DEFAULT_SLOT_CAPACITY

  def shift_time(field)
    stored = value(field)
    SLOT_TIMES.include?(stored) ? stored : TIME_DEFAULTS.fetch(field)
  end

  def slot_ranges(shift)
    (shift == "FULL" ? %w[AM PM] : [ shift ]).map do |period|
      start_time, end_time = SHIFT_TIME_DEFAULTS.fetch(period).keys.map { |field| shift_time(field) }
      SLOT_TIMES.index(start_time)...SLOT_TIMES.index(end_time)
    end
  end

  def time_slot_capacity(shift) = slot_ranges(shift).sum(&:size) * max_bookings_per_slot

  def enabled?(field)
    stored = ActiveModel::Type::Boolean.new.cast(value(field))
    stored.nil? ? SWITCH_DEFAULTS.fetch(field) : stored
  end

  def public_values
    PUBLIC_SWITCH_DEFAULTS.keys.index_with { |field| enabled?(field) }.merge(NOTICE_FIELD => booking_notice)
  end

  def revision
    Digest::SHA256.hexdigest(FIELDS.map { |field| value(field) }.to_json)
  end

  def save(input, actor:, request:)
    audit = { category: "settings", action: "appointment.update", actor: actor, request: request }
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: "appointment" } ], unique_by: :key)
      @record = Setting.lock.find_by!(key: "appointment")
      raise Invalid, STALE unless input["revision"] == revision

      switches = SWITCH_DEFAULTS.keys.select { |field| field.in?([ PHONE_FIELD, Schedule::NIGHT_SETTING ]) || input.key?(field) }
      changes = switches.index_with do |field|
        submitted = input[field]
        raise Invalid, INVALID unless %w[0 1].include?(submitted)

        submitted == "1"
      end.reject { |field, enabled| enabled == enabled?(field) }

      if input.key?(NOTICE_FIELD)
        notice = input[NOTICE_FIELD].to_s.gsub(/\r\n?/, "\n").strip.presence
        changes[NOTICE_FIELD] = notice if notice != booking_notice
      end
      if input.key?(CAPACITY_FIELD)
        capacity = parse_capacity(input[CAPACITY_FIELD]) || raise(Invalid, INVALID_CAPACITY)
        changes[CAPACITY_FIELD] = capacity if capacity != default_capacity
      end
      if input.key?(SLOT_CAPACITY_FIELD)
        capacity = parse_capacity(input[SLOT_CAPACITY_FIELD]) || raise(Invalid, INVALID_SLOT_CAPACITY)
        changes[SLOT_CAPACITY_FIELD] = capacity if capacity != max_bookings_per_slot
      end
      changes.merge!(time_changes(input))

      if changes.any?
        changes.each { |field, value| @record.write_value(field, value) }
        @record.save!
        Log.record!(**audit, target: @record, details: { fields: changes.keys })
      end
    end
    true
  rescue Invalid, ActiveRecord::ActiveRecordError => error
    @record = Setting.find_by(key: "appointment")
    reason = error.is_a?(Invalid) ? error.message : FAILURE
    errors.add(:base, reason)
    fields = FIELDS.select { |field| input.key?(field) }
    Log.record!(**audit, target: @record, status: "failed", details: { fields: fields, reason: reason })
    false
  end

  private

  def value(field) = @record&.settings&.[](field)

  def time_changes(input)
    changes = TIME_DEFAULTS.keys.select { |field| input.key?(field) }.index_with do |field|
      time = input[field]
      raise Invalid, INVALID_TIME unless SLOT_TIMES.include?(time)

      time
    end.reject { |field, time| time == shift_time(field) }

    windows = SHIFT_TIME_DEFAULTS.values.map do |fields|
      fields.keys.map { |field| changes.fetch(field) { shift_time(field) } }
    end
    raise Invalid, INVALID_WINDOW if windows.any? { |start_time, end_time| start_time >= end_time }
    raise Invalid, OVERLAPPING_WINDOWS if windows.each_cons(2).any? { |earlier, later| earlier.last > later.first }

    changes
  end

  def parse_capacity(value)
    number = value.to_s
    return unless /\A[0-9]{1,10}\z/.match?(number)

    capacity = number.to_i
    capacity if capacity.between?(1, 2_147_483_647)
  end
end

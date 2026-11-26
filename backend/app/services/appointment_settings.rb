class AppointmentSettings
  include ActiveModel::Model

  PHONE_FIELD = "require_mobile_auth"
  PUBLIC_SWITCH_DEFAULTS = {
    "show_unscheduled_doctors" => true,
    "require_booking_remark" => false,
    "display_free_fee_when_fee_is_zero" => true,
    "display_hospital_address" => false
  }.freeze
  SWITCH_DEFAULTS = { PHONE_FIELD => false, Schedule::NIGHT_SETTING => false, **PUBLIC_SWITCH_DEFAULTS }.freeze
  NOTICE_FIELD = "booking_notice"
  CAPACITY_FIELD = "default_capacity"
  DEFAULT_CAPACITY = 20
  FIELDS = [ *SWITCH_DEFAULTS.keys, NOTICE_FIELD, CAPACITY_FIELD ].freeze
  STALE = "配置已变化，请核对当前设置后再保存"
  INVALID = "预约规则开关无效，请核对后再保存"
  INVALID_CAPACITY = "默认放号数必须为 1 到 2147483647 的整数"
  FAILURE = "预约设置未保存，请重试"

  class Invalid < StandardError; end

  def initialize
    @record = Setting.find_by(key: "appointment")
  end

  def phone_required? = enabled?(PHONE_FIELD)
  def night_enabled? = enabled?(Schedule::NIGHT_SETTING)
  def booking_notice = value(NOTICE_FIELD)
  def default_capacity = parse_capacity(value(CAPACITY_FIELD)) || DEFAULT_CAPACITY

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

      switches = [ PHONE_FIELD, Schedule::NIGHT_SETTING, *PUBLIC_SWITCH_DEFAULTS.keys.select { |field| input.key?(field) } ]
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

  def parse_capacity(value)
    number = value.to_s
    return unless /\A[0-9]{1,10}\z/.match?(number)

    capacity = number.to_i
    capacity if capacity.between?(1, 2_147_483_647)
  end
end

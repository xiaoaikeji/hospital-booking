class AppointmentSettings
  include ActiveModel::Model

  PHONE_FIELD = "require_mobile_auth"
  SWITCH_FIELDS = [ PHONE_FIELD, Schedule::NIGHT_SETTING ].freeze
  NOTICE_FIELD = "booking_notice"
  FIELDS = [ *SWITCH_FIELDS, NOTICE_FIELD ].freeze
  STALE = "配置已变化，请核对当前设置后再保存"
  INVALID = "请选择是否验证账号手机号和启用晚班"
  FAILURE = "预约设置未保存，请重试"

  class Invalid < StandardError; end

  def initialize
    @record = Setting.find_by(key: "appointment")
  end

  def phone_required? = enabled?(PHONE_FIELD)
  def night_enabled? = enabled?(Schedule::NIGHT_SETTING)
  def booking_notice = value(NOTICE_FIELD)

  def revision
    Digest::SHA256.hexdigest(FIELDS.map { |field| value(field) }.to_json)
  end

  def save(input, actor:, request:)
    audit = { category: "settings", action: "appointment.update", actor: actor, request: request }
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: "appointment" } ], unique_by: :key)
      @record = Setting.lock.find_by!(key: "appointment")
      raise Invalid, STALE unless input["revision"] == revision

      changes = SWITCH_FIELDS.index_with do |field|
        submitted = input[field]
        raise Invalid, INVALID unless %w[0 1].include?(submitted)

        submitted == "1"
      end.reject { |field, enabled| enabled == enabled?(field) }

      if input.key?(NOTICE_FIELD)
        notice = input[NOTICE_FIELD].to_s.gsub(/\r\n?/, "\n").strip.presence
        changes[NOTICE_FIELD] = notice if notice != booking_notice
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
  def enabled?(field) = ActiveModel::Type::Boolean.new.cast(value(field)) == true
end

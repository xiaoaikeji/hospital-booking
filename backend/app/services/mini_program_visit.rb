class MiniProgramVisit
  def self.valid_entry?(context)
    id = context[:entry_id]
    id.nil? || (id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{8,64}\z/) && entry_values(context).any?)
  end

  def self.record(identity, context, ip:)
    return false unless valid_entry?(context)
    device = {}
    simulated = [ context[:device_platform], context[:device_model] ].any? { |v| v.is_a?(String) && v.match?(/devtools|simulator|emulator|模拟器|开发者工具/i) }
    unless simulated
      %i[device_model operating_system].each do |field|
        value = text(context[field], 100)
        device[field.to_s] = value if value && !value.match?(/unknown|devtools|simulator|emulator|未知|模拟器|开发者工具/i)
      end
    end
    device["first_ip"] = ip if ip
    user = identity.user
    if (device.keys - user.login_profile.keys).any?
      user.with_lock do
        missing = device.except(*user.login_profile.keys)
        user.update!(login_profile: user.login_profile.merge(missing)) if missing.any?
      end
    end

    entry = entry_values(context)
    return true if entry.empty?
    identity.with_lock(requires_new: true) do
      id = context[:entry_id]
      # The row lock serializes retries from the same binding, including a lost acknowledgement.
      next if id && Log.exists?(action: "mini_program.entry", target_type: "UserApp", target_id: identity.id, correlation_id: id)
      identity.update!(first_entry: entry) if identity.first_entry.empty?
      Log.record!(source: "user", category: "mini_program", action: "mini_program.entry", actor: user, target: identity, details: entry, correlation_id: id)
    end
    true
  rescue StandardError => error
    Rails.logger.warn("Mini program visit could not be recorded (#{error.class.name})")
    false
  end

  def self.entry_values(context)
    # Older clients sent one scene field. A four-digit launch code and a QR parameter now have distinct fields.
    legacy = text(context[:scene], 128)
    launch = context[:launch_scene]
    launch ||= legacy if legacy&.match?(/\A\d{4}\z/)
    channel = text(context[:channel_scene], 128)
    channel ||= legacy unless launch
    launch = launch.to_i if launch.to_s.match?(/\A[1-9]\d{3}\z/)
    { "launch_scene" => (launch if launch.is_a?(Integer) && launch.between?(1000, 9999)), "channel_scene" => channel }.compact
  end

  def self.text(value, limit)
    return unless value.is_a?(String)
    value = value.strip
    value if value.present? && value.length <= limit && !value.match?(/[[:cntrl:]]/)
  end
  private_class_method :entry_values, :text
end

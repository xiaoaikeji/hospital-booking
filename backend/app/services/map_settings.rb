class MapSettings
  include ActiveModel::Validations
  class Invalid < StandardError; end

  PROVIDERS = { "baidu" => "百度地图", "tencent" => "腾讯地图" }.freeze
  KEY_FIELDS = { "baidu" => "ak", "tencent" => "tencent_key" }.freeze
  FIELDS = {
    "provider" => %w[map provider MAP_PROVIDER],
    "ak" => %w[baidu_map ak BAIDU_MAP_AK],
    "tencent_key" => %w[tencent_map key TENCENT_MAP_KEY]
  }.freeze
  SECTIONS = FIELDS.values.map(&:first).freeze
  KEY_FORMAT = /\A[A-Za-z0-9_-]{1,128}\z/
  LOCK_ID = 71_020_014

  def initialize(rows = Setting.where(key: SECTIONS).index_by(&:key))
    @rows = rows
    @fields = FIELDS.keys.index_with { |field| resolve(field) }
  end

  def value(field) = @fields.fetch(field).first
  def source(field) = @fields.fetch(field).last
  def form_field(field) = IntegrationSettings.form_field(*@fields.fetch(field), public: field == "provider")
  def provider = value("provider")

  def key
    field = KEY_FIELDS[provider]
    value(field) if field
  end

  def stored? = FIELDS.any? { |field, _| !stored_value(field).nil? }

  def revision
    fingerprint(FIELDS.keys.map { |field| [ stored_value(field), @fields.fetch(field) ] })
  end

  # A switch back to a previously used provider starts a new backfill as well.
  def lookup_revision
    field = KEY_FIELDS[provider]
    fingerprint([ provider, key, @rows["map"]&.updated_at&.iso8601(6), field && stored_value(field) ])
  end

  # Held only while publishing a result. The network lookup never holds the configuration lock.
  def self.current_for_lookup?(revision)
    Setting.connection.execute("SELECT pg_advisory_xact_lock_shared(#{LOCK_ID})")
    rows = Setting.where(key: SECTIONS).order(:key).lock("FOR SHARE").index_by(&:key)
    new(rows).lookup_revision == revision
  end

  def save(input, actor:, request:)
    input = input.to_h.stringify_keys
    audit = { category: "settings", action: "map_settings.update", actor: actor, request: request }
    fields = []
    Setting.transaction(requires_new: true) do
      Setting.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_ID})")
      Setting.insert_all([ { key: "map" } ], unique_by: :key)
      rows = Setting.where(key: SECTIONS).order(:key).lock.index_by(&:key)
      current = self.class.new(rows)
      fields = current.submitted_fields(input)
      raise Invalid, "配置已变化，请刷新后再保存" unless input["revision"] == current.revision

      clear = input["clear_settings"] == "1" || input["clear_key"] == "1"
      changed = fields.select { |field| current.update_field(field, input[field], clear: clear) }
      Log.record!(**audit, target: rows.fetch("map"), details: { fields: changed })
    end
    true
  rescue Invalid, IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    errors.add(:base, error.is_a?(Invalid) ? error.message : "地图设置未保存，请核对部署配置")
    Log.record!(**audit, status: "failed", details: { fields: fields })
    false
  end

  protected

  def submitted_fields(input)
    return FIELDS.keys if input["clear_settings"] == "1"
    return [ KEY_FIELDS[provider] ].compact if input["clear_key"] == "1"
    field = KEY_FIELDS[input.fetch("provider", provider)]
    [ "provider", field ].compact & input.keys
  end

  def update_field(field, input, clear:)
    section, name = FIELDS.fetch(field)
    if clear
      return false if stored_value(field).nil?
      replacement = nil
    else
      raise Invalid, "地图服务配置格式无效" unless input.is_a?(String)
      replacement = input.strip
      if field != "provider" && replacement.empty?
        raise Invalid, "请重新填写地图密钥或清除系统配置" if !stored_value(field).nil? && value(field).nil?
        return false
      end
      valid = field == "provider" ? PROVIDERS.key?(replacement) : KEY_FORMAT.match?(replacement)
      raise Invalid, "请填写有效的地图服务配置" unless valid
      return false if replacement == value(field)
    end
    record = @rows[section] ||= Setting.new(key: section)
    record.write_value(name, replacement)
    record.save!
  end

  private

  def stored_value(field)
    section, name = FIELDS.fetch(field)
    @rows[section]&.settings&.fetch(name, nil)
  end

  def resolve(field)
    section, name, env_key = FIELDS.fetch(field)
    value, source = IntegrationSettings.read_with_source(section.to_sym, name.to_sym, env_key: env_key) do
      Setting.decode_value(section, name, stored_value(field))
    end
    if field == "provider"
      return [ "baidu", "系统默认" ] if value.nil?
      return [ nil, "部署配置无效" ] unless PROVIDERS.key?(value)
    else
      return [ nil, "部署配置无效" ] if !value.nil? && !(value.is_a?(String) && KEY_FORMAT.match?(value))
      source = "加密数据库" if source == "系统配置"
    end
    [ value, source ]
  rescue IntegrationSettings::ConfigurationError
    [ nil, "系统配置（解密失败）" ]
  end

  def fingerprint(values)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, values.to_json)
  end
end

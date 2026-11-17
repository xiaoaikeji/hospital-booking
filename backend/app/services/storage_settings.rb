require "digest"

class StorageSettings
  include ActiveModel::Model
  FIELDS = { "service" => [ "active_storage", "service" ], "secret_id" => [ "tencent_cos", "secret_id" ],
    "secret_key" => [ "tencent_cos", "secret_key" ], "region" => [ "tencent_cos", "region" ],
    "bucket" => [ "tencent_cos", "bucket" ], "endpoint" => [ "tencent_cos", "endpoint" ] }.freeze
  SECRETS = %w[secret_id secret_key].freeze
  LABELS = { "service" => "存储方式", "secret_id" => "SecretId", "secret_key" => "SecretKey", "region" => "地域", "bucket" => "桶名", "endpoint" => "API 地址" }.freeze

  def display_value(field)
    @display_values&.key?(field) ? @display_values[field] : read(field)
  end

  def revision = self.class.revision_for(Setting.raw_snapshot)

  def self.revision_for(raw)
    Digest::SHA256.hexdigest(JSON.generate(raw.reject { |_key, value| value.empty? }))
  end

  def read(field)
    section, key = FIELDS.fetch(field)
    IntegrationSettings.read(section.to_sym, key.to_sym, env_key: env_key(field))
  end

  def source(field)
    section, key = FIELDS.fetch(field)
    value = Setting.read_integration_value(section, key)
    return "系统配置" unless value.nil? || (value.is_a?(String) && value.strip.empty?)
    return "环境变量" if ENV[env_key(field)].present?
    return "Rails credentials" if Rails.application.credentials.dig(section, key).present?
    field == "service" ? "默认本地" : "未配置"
  rescue IntegrationSettings::ConfigurationError
    "系统配置（解密失败）"
  end

  def save(input, actor:, request: nil, expected_revision: nil)
    unless input.is_a?(Hash) && (input.keys - FIELDS.keys - [ "clear_fields" ]).empty?
      errors.add(:base, "配置字段无效")
      return false
    end
    clear = input.fetch("clear_fields", [])
    unless clear.is_a?(Array) && (clear - FIELDS.keys).empty? && input.except("clear_fields").values.all? { |value| value.is_a?(String) }
      errors.add(:base, "配置格式无效")
      return false
    end
    @display_values = {}
    Setting.transaction do
      anchor = Setting.find_or_create_by!(key: "active_storage")
      anchor.lock!
      records = { "active_storage" => anchor, "tencent_cos" => Setting.find_or_initialize_by(key: "tencent_cos") }
      old_raw = Setting.raw_snapshot
      if !expected_revision.nil? && expected_revision != self.class.revision_for(old_raw)
        raise IntegrationSettings::ConfigurationError, "配置已被其他操作修改，请刷新页面后重新填写"
      end
      changed = []
      FIELDS.each do |field, (section, key)|
        if clear.include?(field)
          records.fetch(section).write_value(key, nil)
          @display_values[field] = nil unless SECRETS.include?(field)
          changed << field
        elsif input.key?(field) && input[field].strip.present?
          value = input[field].strip
          validate_value!(field, value)
          @display_values[field] = value unless SECRETS.include?(field)
          records.fetch(section).write_value(key, stored_value(field, value))
          changed << field
        end
      end
      values = Setting.decode_snapshot(records.transform_values(&:settings))
      StorageConfiguration.validate!(values)
      protect_existing_files!(old_raw, values)
      records.each_value(&:save!)
      Log.record!(action: "storage_settings.update", category: "security", actor: actor, target: anchor,
        details: { "fields" => changed }, request: request)
    end
    StorageConfiguration.refresh!
    true
  rescue IntegrationSettings::ConfigurationError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    errors.add(:base, error.is_a?(IntegrationSettings::ConfigurationError) ? error.message : "配置保存失败，请核对字段后重试") if errors.empty?
    false
  end

  private

  def env_key(field)
    field == "service" ? "ACTIVE_STORAGE_SERVICE" : "TENCENT_COS_#{field.upcase}"
  end

  def stored_value(field, value)
    return value unless field == "service" && value == "local"
    fallback = IntegrationSettings.with_snapshot({}) { read("service") } || "local"
    fallback == "local" ? nil : value
  end

  def validate_value!(field, value)
    valid = case field
    when "region" then value.match?(/\A[a-z][a-z0-9-]*\z/)
    when "bucket" then value.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    when "endpoint"
      uri = URI.parse(value)
      uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    when *SECRETS then value.length <= 4096 && !value.match?(/\s|\A\*{3,}/)
    else true
    end
    unless valid
      errors.add(field, "配置无效")
      raise IntegrationSettings::ConfigurationError, "#{LABELS.fetch(field)}配置无效"
    end
  rescue URI::InvalidURIError
    errors.add(field, "须为有效的 HTTPS API 地址")
    raise IntegrationSettings::ConfigurationError, "API 地址无效", cause: nil
  end

  def protect_existing_files!(old_raw, values)
    return unless ActiveStorage::Blob.where(service_name: "tencent_cos").exists?
    require "active_storage/service/tencent_cos_service"
    old = IntegrationSettings.with_snapshot(old_raw) do
      %i[bucket region endpoint].to_h do |field|
        [ field, IntegrationSettings.read(:tencent_cos, field, env_key: "TENCENT_COS_#{field.upcase}") ]
      end
    end
    old[:endpoint] ||= "https://cos.#{old[:region]}.myqcloud.com"
    current = IntegrationSettings.with_snapshot(values) { ActiveStorage::Service::TencentCosService.settings }
    if %i[bucket region endpoint].any? { |field| old[field] != current[field] }
      raise IntegrationSettings::ConfigurationError, "已有 COS 附件，变更桶、地域或 API 地址前需先迁移文件"
    end
  end
end

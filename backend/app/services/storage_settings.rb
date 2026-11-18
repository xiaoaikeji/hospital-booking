require "digest"

class StorageSettings
  include ActiveModel::Model
  class StaleRevision < IntegrationSettings::ConfigurationError; end

  attr_reader :refresh_warning

  FIELDS = { "service" => [ "active_storage", "service" ], "secret_id" => [ "tencent_cos", "secret_id" ],
    "secret_key" => [ "tencent_cos", "secret_key" ], "region" => [ "tencent_cos", "region" ],
    "bucket" => [ "tencent_cos", "bucket" ], "endpoint" => [ "tencent_cos", "endpoint" ] }.freeze
  SECRETS = %w[secret_id secret_key].freeze
  LABELS = { "service" => "存储方式", "secret_id" => "SecretId", "secret_key" => "SecretKey", "region" => "地域", "bucket" => "桶名", "endpoint" => "API 地址" }.freeze

  def form_value(field, source:)
    return @display_values[field] if @display_values&.key?(field)
    read(field) if field == "service" || source == "系统配置"
  end

  def revision = self.class.revision_for(Setting.raw_snapshot)

  def self.revision_for(raw)
    Digest::SHA256.hexdigest(JSON.generate(raw.reject { |_key, value| value.empty? }))
  end

  def read(field)
    return StorageConfiguration.service_name if field == "service"

    section, key = FIELDS.fetch(field)
    IntegrationSettings.read(section.to_sym, key.to_sym, env_key: env_key(field))
  end

  def source(field)
    section, key = FIELDS.fetch(field)
    value = Setting.read_integration_value(section, key)
    return "系统配置" unless IntegrationSettings.unset?(value)
    return "环境变量" unless IntegrationSettings.unset?(ENV[env_key(field)])
    return "Rails credentials" unless IntegrationSettings.unset?(Rails.application.credentials.dig(section.to_sym, key.to_sym))
    field == "service" ? "默认本地" : "未配置"
  rescue IntegrationSettings::ConfigurationError
    "系统配置（解密失败）"
  end

  def save(input, actor:, request: nil, expected_revision: nil)
    errors.clear
    @display_values = {}
    @refresh_warning = nil
    audit = { category: "security", actor: actor, request: request }
    anchor = persist(input, expected_revision, audit)
    return false unless anchor

    ActiveRecord.after_all_transactions_commit { refresh_client(anchor, audit) }
    true
  end

  private

  def persist(input, expected_revision, audit)
    unless input.is_a?(Hash) && (input.keys - FIELDS.keys - [ "clear_fields" ]).empty?
      raise IntegrationSettings::ConfigurationError, "配置字段无效"
    end
    clear = input.fetch("clear_fields", [])
    unless clear.is_a?(Array) && (clear - FIELDS.keys).empty? && input.except("clear_fields").values.all? { |value| value.is_a?(String) }
      raise IntegrationSettings::ConfigurationError, "配置格式无效"
    end
    Setting.transaction(requires_new: true) do
      anchor = Setting.find_or_create_by!(key: "active_storage")
      anchor.lock!
      records = { "active_storage" => anchor, "tencent_cos" => Setting.find_or_initialize_by(key: "tencent_cos") }
      old_raw = Setting.raw_snapshot
      if !expected_revision.nil? && expected_revision != self.class.revision_for(old_raw)
        raise StaleRevision, "配置已被其他操作修改，请刷新页面后重新填写"
      end
      changed = []
      FIELDS.each do |field, (section, key)|
        record = records.fetch(section)
        if clear.include?(field)
          next unless record.settings.key?(key)

          record.write_value(key, nil)
          @display_values[field] = nil unless field == "service" || SECRETS.include?(field)
          changed << field
        elsif input.key?(field) && input[field].strip.present?
          value = input[field].strip
          @display_values[field] = value unless SECRETS.include?(field)
          validate_value!(field, value)
          current = record.settings[key]
          value = stored_value(field, value, current: current)
          next if value == current

          record.write_value(key, value)
          changed << field
        end
      end
      values = Setting.decode_snapshot(records.transform_values(&:settings))
      StorageConfiguration.validate!(values)
      protect_existing_files!(old_raw, values)
      records.each_value(&:save!)
      Log.record!(**audit, action: "storage_settings.update", target: anchor, details: { "fields" => changed })
      anchor
    end
  rescue IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    reason = case error
    when StaleRevision then "配置版本冲突"
    when IntegrationSettings::ConfigurationError then "配置校验失败"
    else "数据库写入失败"
    end
    fields = input.is_a?(Hash) ? FIELDS.keys & (input.keys + Array.wrap(input["clear_fields"])) : []
    Log.record!(**audit, action: "storage_settings.update", status: "failed", details: { "fields" => fields, "reason" => reason })
    errors.add(:base, error.is_a?(IntegrationSettings::ConfigurationError) ? error.message : "配置保存失败，请重试") if errors.empty?
    false
  end

  def refresh_client(anchor, audit)
    StorageConfiguration.refresh!
  rescue StandardError
    @refresh_warning = "配置已保存，存储客户端刷新失败"
    Log.record!(**audit, action: "storage_settings.refresh", target: anchor, status: "failed", details: { "reason" => @refresh_warning })
  end

  def env_key(field)
    field == "service" ? "ACTIVE_STORAGE_SERVICE" : "TENCENT_COS_#{field.upcase}"
  end

  def stored_value(field, value, current:)
    return value unless field == "service"
    return value if value == current && value != "local"

    fallback = IntegrationSettings.with_snapshot({}) { read("service") }
    value == fallback ? nil : value
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

class StorageSettings
  include ActiveModel::Model
  class StaleRevision < IntegrationSettings::ConfigurationError; end

  attr_reader :refresh_warning

  FIELDS = { "service" => [ "active_storage", "service" ], "secret_id" => [ "tencent_cos", "secret_id" ],
    "secret_key" => [ "tencent_cos", "secret_key" ], "region" => [ "tencent_cos", "region" ],
    "bucket" => [ "tencent_cos", "bucket" ], "endpoint" => [ "tencent_cos", "endpoint" ] }.freeze
  PUBLIC_FIELDS = %w[service region bucket endpoint].freeze
  LABELS = { "service" => "存储方式", "secret_id" => "SecretId", "secret_key" => "SecretKey", "region" => "地域", "bucket" => "桶名", "endpoint" => "API 地址" }.freeze

  def form_field(field)
    public_field = PUBLIC_FIELDS.include?(field)
    value, source = effective_field(field)
    value = @display_values.fetch(field, value) if @display_values
    if field == "endpoint" && value && !IntegrationSettings.https_origin?(value)
      value = nil
    end
    IntegrationSettings.form_field(value, source, public: public_field)
  end

  def revision = StorageConfiguration.fingerprint(Setting.raw_snapshot)
  def stored? = Setting.raw_snapshot.values.any?(&:present?)

  def read(field)
    return StorageConfiguration.service_name if field == "service"

    section, key = FIELDS.fetch(field)
    value = IntegrationSettings.read(section.to_sym, key.to_sym, env_key: env_key(field))
    return StorageConfiguration.default_cos_endpoint(read("region")) if field == "endpoint" && value.nil?
    value
  end

  def source(field) = effective_field(field).last

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

  def effective_field(field)
    section, key = FIELDS.fetch(field)
    value, source = IntegrationSettings.read_with_source(section.to_sym, key.to_sym, env_key: env_key(field))
    return [ value, source ] unless value.nil?
    return [ "local", "默认本地" ] if field == "service"
    if field == "endpoint" && (endpoint = StorageConfiguration.default_cos_endpoint(read("region")))
      return [ endpoint, "按地域生成" ]
    end
    [ nil, source ]
  rescue IntegrationSettings::ConfigurationError
    [ nil, IntegrationSettings::DAMAGED_SOURCE ]
  end

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
      if !expected_revision.nil? && expected_revision != StorageConfiguration.fingerprint(old_raw)
        raise StaleRevision, "配置已被其他操作修改，请刷新页面后重新填写"
      end
      changed = []
      FIELDS.each do |field, (section, key)|
        record = records.fetch(section)
        if clear.include?(field)
          next unless record.settings.key?(key)

          record.write_value(key, nil)
          @display_values[field] = nil if field != "service" && PUBLIC_FIELDS.include?(field)
          changed << field
        elsif input.key?(field) && input[field].strip.present?
          value = input[field].strip
          @display_values[field] = value if PUBLIC_FIELDS.include?(field)
          validate_value!(field, value)
          next if unchanged_value?(field, value)

          value = nil if field == "service" && value == IntegrationSettings.with_snapshot({}) { read("service") }
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

  def unchanged_value?(field, value)
    current = read(field)
    return current == value if field == "service"
    current.is_a?(String) && current.strip == value
  rescue IntegrationSettings::ConfigurationError
    # 显式输入的新密钥仍可替换已损坏的密文。
    false
  end

  def validate_value!(field, value)
    valid = case field
    when "region" then value.match?(/\A[a-z][a-z0-9-]*\z/)
    when "bucket" then value.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    when "endpoint"
      uri = URI.parse(value)
      uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    when *Setting.secret_fields("tencent_cos")
      value.length <= 4096 && !value.match?(/\s|\A\*{3,}/) && !IntegrationSettings.redacted_value?(value)
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

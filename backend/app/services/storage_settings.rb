class StorageSettings
  include ActiveModel::Model
  class StaleRevision < IntegrationSettings::ConfigurationError; end

  attr_reader :refresh_warning

  FIELDS = { "service" => [ "active_storage", "service" ], "secret_id" => [ "tencent_cos", "secret_id" ],
    "secret_key" => [ "tencent_cos", "secret_key" ], "region" => [ "tencent_cos", "region" ],
    "bucket" => [ "tencent_cos", "bucket" ], "endpoint" => [ "tencent_cos", "endpoint" ] }.freeze
  PUBLIC_FIELDS = %w[service region bucket].freeze
  ENDPOINT_PUBLIC_DIGEST = "endpoint_public_digest"
  LABELS = { "service" => "存储方式", "secret_id" => "SecretId", "secret_key" => "SecretKey", "region" => "地域", "bucket" => "桶名", "endpoint" => "API 地址" }.freeze

  def form_field(field)
    value, source = effective_field(field)
    return endpoint_form_field(value, source) if field == "endpoint"
    return IntegrationSettings.form_field(value, source) unless PUBLIC_FIELDS.include?(field)

    if @display_values&.key?(field)
      value = @display_values[field]
    elsif field != "service" && value.is_a?(String)
      value = value.strip
    end
    unless value.nil? || StorageConfiguration.valid_value?(field, value)
      value, source = nil, IntegrationSettings::INVALID_SOURCE
    end
    IntegrationSettings.form_field(value, source, public: true)
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
    @endpoint_submitted = false
    @refresh_warning = nil
    audit = { category: "security", actor: actor, request: request }
    anchor = persist(input, expected_revision, audit)
    return false unless anchor

    @endpoint_submitted = false
    ActiveRecord.after_all_transactions_commit { refresh_client(anchor, audit) }
    true
  end

  private

  def endpoint_form_field(value, source)
    value = value.strip if value.is_a?(String)
    if !value.nil? && !StorageConfiguration.valid_value?("endpoint", value)
      return IntegrationSettings.form_field(nil, IntegrationSettings::INVALID_SOURCE)
    end

    public = value && !@endpoint_submitted && (source == "按地域生成" ||
      endpoint_digest(value) == Setting.read_integration_value(:tencent_cos, ENDPOINT_PUBLIC_DIGEST))
    IntegrationSettings.form_field(value, source, public: public)
  end

  def endpoint_digest(value)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "tencent_cos.endpoint:#{value}")
  end

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
    unless input.is_a?(Hash) && (input.keys - FIELDS.keys - %w[clear_fields endpoint_visibility]).empty?
      raise IntegrationSettings::ConfigurationError, "配置字段无效"
    end
    clear = input.fetch("clear_fields", [])
    visibility = input.fetch("endpoint_visibility", "")
    values = input.except("clear_fields", "endpoint_visibility")
    unless clear.is_a?(Array) && (clear - FIELDS.keys).empty? && [ "", "public", "private" ].include?(visibility) &&
        values.values.all? { |value| value.is_a?(String) }
      raise IntegrationSettings::ConfigurationError, "配置格式无效"
    end
    submitted = values.except(*clear).transform_values(&:strip).compact_blank
    clear_endpoint = clear.include?("endpoint")
    @endpoint_submitted = clear_endpoint || submitted.key?("endpoint")
    Setting.transaction(requires_new: true) do
      anchor = Setting.find_or_create_by!(key: "active_storage")
      anchor.lock!
      records = { "active_storage" => anchor, "tencent_cos" => Setting.find_or_initialize_by(key: "tencent_cos") }
      old_raw = Setting.raw_snapshot
      if !expected_revision.nil? && expected_revision != StorageConfiguration.fingerprint(old_raw)
        raise StaleRevision, "配置已被其他操作修改，请刷新页面后重新填写"
      end
      validate_inputs!(submitted, clear_endpoint ? "" : visibility)
      changed = []
      FIELDS.each do |field, (section, key)|
        record = records.fetch(section)
        if clear.include?(field)
          next unless record.settings.key?(key)

          record.write_value(key, nil)
          @display_values[field] = nil if field != "service" && PUBLIC_FIELDS.include?(field)
          changed << field
        elsif (value = submitted[field])
          legacy_endpoint = field == "endpoint" && Setting.legacy_storage_endpoint?(section, key, record.settings[key])
          next if !legacy_endpoint && unchanged_value?(field, value)

          value = nil if field == "service" && value == IntegrationSettings.with_snapshot({}) { read("service") }
          record.write_value(key, value)
          changed << field
        end
      end
      if update_endpoint_visibility(records.fetch("tencent_cos"), submitted["endpoint"], visibility, clear_endpoint)
        changed |= %w[endpoint]
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
    fields |= %w[endpoint] if input.is_a?(Hash) && input["endpoint_visibility"].present?
    Log.record!(**audit, action: "storage_settings.update", status: "failed", details: { "fields" => fields, "reason" => reason })
    errors.add(:base, error.is_a?(IntegrationSettings::ConfigurationError) ? error.message : "配置保存失败，请重试") if errors.empty?
    false
  end

  def update_endpoint_visibility(record, endpoint, visibility, clear)
    previous = record.settings[ENDPOINT_PUBLIC_DIGEST]
    digest = if clear || visibility == "private"
      nil
    elsif visibility == "public"
      endpoint_digest(endpoint)
    elsif endpoint
      previous if previous == endpoint_digest(endpoint)
    else
      previous
    end
    return false if digest == previous

    record.write_value(ENDPOINT_PUBLIC_DIGEST, digest)
    true
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

  def validate_inputs!(submitted, visibility)
    submitted.each do |field, value|
      if PUBLIC_FIELDS.include?(field)
        valid = StorageConfiguration.valid_value?(field, value)
        @display_values[field] = valid ? value : nil
      elsif field == "endpoint"
        valid = StorageConfiguration.valid_value?(field, value)
      else
        valid = value.length <= 4096 && !value.match?(/\s|\A\*{3,}/) && !IntegrationSettings.redacted_value?(value)
      end
      errors.add(field, field == "endpoint" ? "须为有效的 HTTPS API 地址" : "配置无效") unless valid
    end
    if visibility == "public" && !submitted.key?("endpoint")
      errors.add("endpoint", "请填写要回显的 HTTPS API 地址")
    end
    field = errors.attribute_names.first
    raise IntegrationSettings::ConfigurationError, "#{LABELS.fetch(field.to_s)}配置无效" if field
  end

  def protect_existing_files!(old_raw, values)
    return unless ActiveStorage::Blob.where(service_name: "tencent_cos").exists?
    require "active_storage/service/tencent_cos_service"
    location = old_raw.fetch("tencent_cos", {}).slice("bucket", "region", "endpoint")
    old = IntegrationSettings.with_snapshot(Setting.decode_snapshot("tencent_cos" => location)) do
      %i[bucket region endpoint].to_h do |field|
        value = IntegrationSettings.read(:tencent_cos, field, env_key: "TENCENT_COS_#{field.upcase}")
        [ field, value.is_a?(String) ? value.strip : value ]
      end
    end
    old[:endpoint] ||= StorageConfiguration.default_cos_endpoint(old[:region])
    current = IntegrationSettings.with_snapshot(values) { ActiveStorage::Service::TencentCosService.settings }
    if %i[bucket region endpoint].any? { |field| old[field] != current[field] }
      raise IntegrationSettings::ConfigurationError, "已有 COS 附件，变更桶、地域或 API 地址前需先迁移文件"
    end
  end
end

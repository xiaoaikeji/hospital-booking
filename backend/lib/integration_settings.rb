require "uri"

# 仅用于密钥、证书及其配套参数，不缓存明文。
module IntegrationSettings
  class ConfigurationError < StandardError; end

  DAMAGED_SOURCE = "系统配置（解密失败）"
  INVALID_SOURCE = "部署配置无效"
  FormField = Data.define(:value, :source, :configured, :write_only) do
    def status = configured ? "已配置" : "未配置"
  end

  # Views and administrative responses only receive this projection. Opt in for public fields.
  def self.form_field(value = nil, source = "未配置", public: false)
    configured = !unset?(value)
    return FormField.new(value:, source:, configured:, write_only: false) if public

    warning = source.presence_in([ DAMAGED_SOURCE, INVALID_SOURCE ])
    FormField.new(value: nil, source: warning, configured:, write_only: true)
  end

  def self.redacted_value?(value)
    value.is_a?(String) && value.strip.match?(/\A(?:已配置|未配置|\[FILTERED\]|[^\s]{0,4}[*•●]{3,}[^\s]{0,4})\z/i)
  end

  def self.https_origin?(value)
    return false unless value.is_a?(String)

    uri = URI.parse(value)
    uri.is_a?(URI::HTTPS) && uri.host.present? && uri.path.in?([ "", "/" ]) &&
      uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  def self.read(...) = read_with_source(...).first

  def self.read_with_source(section, key, env_key:, env: ENV, credentials: Rails.application.credentials)
    reader = ActiveSupport::IsolatedExecutionState[:integration_settings_reader] || Rails.application.config.x.integration_settings_reader
    value = block_given? ? yield : reader&.call(section, key)
    return [ value, "系统配置" ] unless unset?(value)
    value = env[env_key]
    return [ value, "环境变量" ] unless unset?(value)
    value = credentials.dig(section, key)
    unset?(value) ? [ nil, "未配置" ] : [ value, "Rails credentials" ]
  end

  # 同一次校验和客户端创建使用相同快照，避免并发更新时混用两版字段。
  def self.with_snapshot(values)
    previous = ActiveSupport::IsolatedExecutionState[:integration_settings_reader]
    ActiveSupport::IsolatedExecutionState[:integration_settings_reader] = ->(section, field) { values.dig(section.to_s, field.to_s) }
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:integration_settings_reader] = previous
  end

  def self.unset?(value)
    value.nil? || (value.is_a?(String) && value.strip.empty?)
  end
end

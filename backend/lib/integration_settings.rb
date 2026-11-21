# 仅用于密钥、证书及其配套参数，不缓存明文。
module IntegrationSettings
  class ConfigurationError < StandardError; end

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

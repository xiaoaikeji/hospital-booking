require "test_helper"

class IntegrationSettingsTest < ActiveSupport::TestCase
  setup do
    @previous_reader = Rails.application.config.x.integration_settings_reader
    Rails.application.config.x.integration_settings_reader = nil
  end

  teardown do
    Rails.application.config.x.integration_settings_reader = @previous_reader
  end

  test "system settings take precedence over environment and credentials" do
    Rails.application.config.x.integration_settings_reader = ->(section, key) { "system-value" if [ section, key ] == [ :tencent_cos, :secret_key ] }
    assert_equal "system-value", read_value(env: { "TENCENT_COS_SECRET_KEY" => "env-value" })
  end

  test "environment takes precedence over credentials when system setting is absent" do
    assert_equal "env-value", read_value(env: { "TENCENT_COS_SECRET_KEY" => "env-value" })
  end

  test "credentials are used as the final source" do
    assert_equal "credentials-value", read_value
  end

  test "blank values fall through and missing secrets have no default" do
    Rails.application.config.x.integration_settings_reader = ->(_section, _key) { " " }
    assert_nil read_value(env: { "TENCENT_COS_SECRET_KEY" => "" }, credentials: {})
  end

  test "invalid configured values are not replaced by another source" do
    Rails.application.config.x.integration_settings_reader = ->(_section, _key) { false }
    assert_equal false, read_value
  end

  test "system reader errors are not hidden by fallback credentials" do
    Rails.application.config.x.integration_settings_reader = ->(_section, _key) { raise "settings unavailable" }
    assert_raises(RuntimeError) { read_value }
  end

  private

  def read_value(env: {}, credentials: { tencent_cos: { secret_key: "credentials-value" } })
    IntegrationSettings.read(:tencent_cos, :secret_key, env_key: "TENCENT_COS_SECRET_KEY", env: env, credentials: credentials)
  end
end

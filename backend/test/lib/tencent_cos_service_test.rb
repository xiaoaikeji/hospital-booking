require "test_helper"
require "active_storage/service/tencent_cos_service"

class TencentCosServiceTest < ActiveSupport::TestCase
  setup do
    @previous_reader = Rails.application.config.x.integration_settings_reader
    Rails.application.config.x.integration_settings_reader = nil
    @env = {
      "TENCENT_COS_SECRET_ID" => "test-secret-id",
      "TENCENT_COS_SECRET_KEY" => "test-secret-key",
      "TENCENT_COS_REGION" => "ap-shanghai",
      "TENCENT_COS_BUCKET" => "test-bucket-1234567890"
    }
  end

  teardown do
    Rails.application.config.x.integration_settings_reader = @previous_reader
  end

  test "missing configuration reports field names without a production fallback" do
    error = assert_raises(IntegrationSettings::ConfigurationError) do
      ActiveStorage::Service::TencentCosService.settings(env: {}, credentials: {})
    end
    assert_includes error.message, "未配置"
    assert_includes error.message, "secret_id"
    assert_includes error.message, "bucket"
  end

  test "system values take priority and an invalid value does not fall through" do
    Rails.application.config.x.integration_settings_reader = ->(_section, key) { false if key == :secret_key }
    error = assert_raises(IntegrationSettings::ConfigurationError) { settings }
    assert_includes error.message, "secret_key"
    assert_not_includes error.message, "test-secret-key"
  end

  test "unsafe or malformed endpoints fail without exposing the value" do
    endpoints = [
      "http://example.test", "https://secret:password@example.test", "not a URL",
      "https://HOOKS.SLACK-GOV.COM./services/demo-workspace/demo-channel/demo-path-key",
      "https://discord.com/api/v10/%77ebhooks/0000/demo-path-key",
      "https://open.feishu.cn/open-apis/bot/hook/demo-path-key",
      "https://open.larksuite.com/open-apis/bot/v2/hook/demo-path-key",
      "https://fixture-tenant.webhook.office.com/webhookb2/demo/IncomingWebhook/demo-path-key",
      "https://outlook.office.com/webhook/demo/IncomingWebhook/demo-path-key",
      "https://api.telegram.org/file/bot0000:demo-path-key/test.png"
    ]
    endpoints.each do |endpoint|
      @env["TENCENT_COS_ENDPOINT"] = endpoint
      error = assert_raises(IntegrationSettings::ConfigurationError) { settings }
      assert_not_includes error.message, endpoint
      assert_not_includes error.message, "demo-path-key"
    end
  end

  test "SDK uploads and deletes use explicit credentials and compatible checksums" do
    service = ActiveStorage::Service::TencentCosService.new(env: @env, credentials: {}, stub_responses: true)
    checksum = Digest::MD5.base64digest("storage smoke test")
    service.upload("test-key", StringIO.new("storage smoke test"), checksum: checksum)
    service.delete("test-key")

    client = service.client.client
    assert_equal [ :put_object, :delete_object ], client.api_requests.map { |request| request[:operation_name] }
    assert_equal "test-bucket-1234567890", client.api_requests.first[:params][:bucket]
    assert_equal checksum, client.api_requests.first[:params][:content_md5]
    assert_equal "when_required", client.config.request_checksum_calculation
    assert_not_includes service.inspect, "test-secret"
  end

  test "provider error details and causes stay behind the storage boundary" do
    service = ActiveStorage::Service::TencentCosService.new(env: @env, credentials: {}, stub_responses: true)
    client = service.client.client
    context = Seahorse::Client::RequestContext.new
    marker = @env.fetch("TENCENT_COS_SECRET_ID")
    client.stub_responses(:delete_object, Aws::S3::Errors::AccessDenied.new(context, marker))

    error = assert_raises(ActiveStorage::Service::TencentCosService::RequestFailed) { service.delete("fixture-key") }
    assert_equal "腾讯云 COS 请求失败，请稍后重试", error.message
    assert_nil error.cause
    assert_not_includes error.full_message, marker

    client.stub_responses(:get_object, Aws::S3::Errors::NoSuchKey.new(context, marker))
    missing = assert_raises(ActiveStorage::FileNotFoundError) { service.download("fixture-key") }
    assert_nil missing.cause
    assert_not_includes missing.full_message, marker
  end

  private

  def settings
    ActiveStorage::Service::TencentCosService.settings(env: @env, credentials: {})
  end
end

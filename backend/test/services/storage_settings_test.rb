require "test_helper"
require "aws-sdk-s3"

class StorageSettingsTest < ActiveSupport::TestCase
  setup do
    @previous_service_env = ENV["ACTIVE_STORAGE_SERVICE"]
    ENV["ACTIVE_STORAGE_SERVICE"] = "local"
    @aws_options = Aws.config[:s3]
    Aws.config[:s3] = { stub_responses: true }
    @admin = Admin.create!(username: "root", role: "super_admin")
    @input = { "service" => "local", "secret_id" => "test-only-id", "secret_key" => "test-only-secret",
      "bucket" => "test-bucket-123", "region" => "ap-shanghai" }
    StorageConfiguration.reset!
  end

  teardown do
    ENV["ACTIVE_STORAGE_SERVICE"] = @previous_service_env
    Aws.config[:s3] = @aws_options
    StorageConfiguration.reset!
  end

  test "stored credentials are encrypted and the real reader honors database priority" do
    assert StorageSettings.new.save(@input, actor: @admin)
    raw = Setting.find_by!(key: "tencent_cos").settings.to_json
    assert_not_includes raw, "test-only-secret"
    assert StorageSettings.new.save(@input.merge("region" => "ap-beijing"), actor: @admin)
    assert_equal [ "region" ], Log.last.details.fetch("fields")
    assert_equal "test-only-secret", IntegrationSettings.read(:tencent_cos, :secret_key,
      env_key: "TENCENT_COS_SECRET_KEY", env: { "TENCENT_COS_SECRET_KEY" => "fallback" }, credentials: {})
    assert_not_includes Log.last.attributes.to_json, "test-only-secret"
  end

  test "blank and absent fields keep secrets while explicit clearing restores fallback" do
    assert StorageSettings.new.save(@input, actor: @admin)
    encrypted = Setting.find_by!(key: "tencent_cos").settings.fetch("secret_key")
    assert StorageSettings.new.save({ "bucket" => "updated-bucket-123", "secret_key" => " " }, actor: @admin)
    assert_equal encrypted, Setting.find_by!(key: "tencent_cos").settings.fetch("secret_key")
    assert_equal "test-only-id", Setting.read_integration_value(:tencent_cos, :secret_id)
    assert StorageSettings.new.save({ "clear_fields" => [ "secret_key" ] }, actor: @admin)
    assert_equal "fallback", IntegrationSettings.read(:tencent_cos, :secret_key,
      env_key: "TENCENT_COS_SECRET_KEY", env: { "TENCENT_COS_SECRET_KEY" => "fallback" }, credentials: {})
  end

  test "local storage removes a redundant override while retaining COS credentials" do
    assert StorageSettings.new.save(@input, actor: @admin)
    assert_nil Setting.read_integration_value(:active_storage, :service)
    encrypted = Setting.find_by!(key: "tencent_cos").settings.fetch("secret_key")
    assert StorageSettings.new.save({ "service" => "tencent_cos" }, actor: @admin)
    assert StorageSettings.new.save({ "service" => "local" }, actor: @admin)
    assert_nil Setting.read_integration_value(:active_storage, :service)
    assert_equal "local", StorageSettings.new.read("service")
    assert_equal encrypted, Setting.find_by!(key: "tencent_cos").settings.fetch("secret_key")
  end

  test "clearing the storage form audits only keys actually removed from the database" do
    form = StorageSettings.new
    assert form.save({ "region" => "ap-shanghai" }, actor: @admin)
    clear_all = { "clear_fields" => StorageSettings::FIELDS.keys }
    assert form.save(clear_all, actor: @admin)
    assert_nil Setting.read_integration_value(:tencent_cos, :region)
    assert_equal [ "region" ], Log.last.details.fetch("fields")

    assert form.save(clear_all, actor: @admin)
    assert_empty Log.last.details.fetch("fields")
  end

  test "an explicit local choice still overrides external COS configuration" do
    ENV["ACTIVE_STORAGE_SERVICE"] = "tencent_cos"
    assert StorageSettings.new.save(@input, actor: @admin)
    assert_equal "local", Setting.read_integration_value(:active_storage, :service)
    assert_equal "local", StorageSettings.new.read("service")
    assert_equal "系统配置", StorageSettings.new.source("service")
  end

  test "invalid or unknown configuration is rejected without partial writes" do
    assert StorageSettings.new.save(@input, actor: @admin)
    before = Setting.raw_snapshot
    form = StorageSettings.new
    assert_not form.save({ "bucket" => "changed-123", "endpoint" => "http://unsafe.example" }, actor: @admin)
    assert_equal before, Setting.raw_snapshot
    assert_not StorageSettings.new.save({ "unregistered" => "value" }, actor: @admin)
    assert_equal [], Log.last.details.fetch("fields")
    assert_not StorageSettings.new.save({ "secret_key" => false }, actor: @admin)
    assert_not StorageSettings.new.save({ "secret_key" => "****masked" }, actor: @admin)
  end

  test "only missing services default to local and false credentials can be explicitly overridden" do
    ENV.delete("ACTIVE_STORAGE_SERVICE")
    credentials = Rails.application.credentials
    previous = credentials[:active_storage]
    had_section = credentials.keys.include?(:active_storage)
    credentials[:active_storage] = { service: "  " }
    assert_equal "local", StorageConfiguration.validate!({})
    credentials[:active_storage] = { service: false }
    assert_equal "Rails credentials", StorageSettings.new.source("service")
    assert_raises(IntegrationSettings::ConfigurationError) { StorageConfiguration.validate!({}) }
    assert StorageSettings.new.save({ "service" => "local" }, actor: @admin)
    assert_equal "local", Setting.read_integration_value(:active_storage, :service)
  ensure
    if had_section
      credentials[:active_storage] = previous
    else
      credentials.delete(:active_storage)
    end
  end

  test "a database rejection rolls back settings and leaves only a redacted failure audit" do
    Setting.connection.add_check_constraint(:settings, "settings->>'bucket' <> 'rejected-123'", name: "test_storage_bucket")
    before = Setting.raw_snapshot
    form = StorageSettings.new
    assert_difference "Log.count", 1 do
      assert_not form.save(@input.merge("bucket" => "rejected-123"), actor: @admin)
    end
    assert_equal before, Setting.raw_snapshot
    assert_equal "failed", Log.last.status
    assert_equal "数据库写入失败", Log.last.details.fetch("reason")
    assert_equal @input.keys.sort, Log.last.details.fetch("fields").sort
    assert_not_includes form.errors.full_messages.join, "rejected-123"
  end

  test "damaged ciphertext raises instead of silently using a fallback" do
    assert StorageSettings.new.save(@input, actor: @admin)
    record = Setting.find_by!(key: "tencent_cos")
    record.update_columns(settings: record.settings.merge("secret_key" => { "ciphertext" => "damaged" }))
    error = assert_raises(IntegrationSettings::ConfigurationError) do
      IntegrationSettings.read(:tencent_cos, :secret_key, env_key: "TENCENT_COS_SECRET_KEY",
        env: { "TENCENT_COS_SECRET_KEY" => "fallback" }, credentials: {})
    end
    assert_includes error.message, "解密失败"
    form = StorageSettings.new
    field = form.form_field("secret_key")
    assert_equal IntegrationSettings::DAMAGED_SOURCE, field.source
    assert_nil field.value
    assert form.save({ "secret_key" => "test-repaired-key" }, actor: @admin)
    assert_equal "test-repaired-key", form.read("secret_key")
    assert_equal "已配置", form.form_field("secret_key").status
  end

  test "an open form cannot copy an old inherited secret over an external rotation" do
    previous = ENV["TENCENT_COS_SECRET_KEY"]
    ENV["TENCENT_COS_SECRET_KEY"] = "test-first-key"
    form = StorageSettings.new
    revision = form.revision
    assert_nil form.form_field("secret_key").value
    ENV["TENCENT_COS_SECRET_KEY"] = "test-next-key"
    assert_not form.save({ "secret_key" => "" }, actor: @admin, expected_revision: revision)
    assert_includes form.errors[:base].join, "刷新页面"
    assert_nil Setting.read_integration_value(:tencent_cos, :secret_key)
    assert_equal "test-next-key", form.read("secret_key")
  ensure
    ENV["TENCENT_COS_SECRET_KEY"] = previous
  end

  test "an outdated settings form cannot overwrite a newer save" do
    form = StorageSettings.new
    first_revision = form.revision
    assert form.save(@input, actor: @admin, expected_revision: first_revision)
    assert StorageSettings.new.save({ "bucket" => "newer-bucket-123" }, actor: @admin)
    stale = StorageSettings.new
    assert_not stale.save({ "bucket" => "stale-bucket-123" }, actor: @admin, expected_revision: first_revision)
    assert_equal "newer-bucket-123", Setting.read_integration_value(:tencent_cos, :bucket)
    assert_includes stale.errors[:base].join, "刷新页面"
    assert_equal "failed", Log.last.status
    assert_equal({ "fields" => [ "bucket" ], "reason" => "配置版本冲突" }, Log.last.details)
  end

  test "the next refresh observes changes made outside the current client instance" do
    assert StorageSettings.new.save(@input, actor: @admin)
    original = ActiveStorage::Blob.services
    StorageConfiguration.refresh!
    assert_same original, ActiveStorage::Blob.services
    record = Setting.find_by!(key: "tencent_cos")
    record.write_value("secret_key", "rotated-test-secret")
    record.save!
    StorageConfiguration.refresh!
    assert_not_same original, ActiveStorage::Blob.services
    assert_equal "test", ActiveStorage::Blob.service.name.to_s
  end

  test "existing COS attachments prevent changing their storage location but allow key rotation" do
    endpoint = "https://storage.example.invalid/cos/current"
    assert StorageSettings.new.save(@input.merge("endpoint" => endpoint, "endpoint_visibility" => "public"), actor: @admin)
    blob = ActiveStorage::Blob.create!(key: "retained-cos-file", filename: "retained.txt", byte_size: 1,
      checksum: Digest::MD5.base64digest("a"), content_type: "text/plain", service_name: "tencent_cos")
    form = StorageSettings.new
    assert_not form.save({ "bucket" => "other-bucket-123" }, actor: @admin)
    assert_includes form.errors.full_messages.join, "先迁移文件"
    assert_equal "test-bucket-123", Setting.read_integration_value(:tencent_cos, :bucket)
    assert StorageSettings.new.save({ "secret_key" => "rotated-test-secret" }, actor: @admin)
    assert StorageSettings.new.save({ "endpoint_visibility" => "private" }, actor: @admin)
    assert_nil StorageSettings.new.form_field("endpoint").value
    assert_equal endpoint, Setting.read_integration_value(:tencent_cos, :endpoint)
  ensure
    ActiveStorage::Blob.where(id: blob.id).delete_all if blob
  end

  test "approval of a deployment address does not persist an override or carry over to a replacement" do
    previous = ENV["TENCENT_COS_ENDPOINT"]
    endpoint = "https://gateway.example.invalid/s3/v1"
    ENV["TENCENT_COS_ENDPOINT"] = endpoint
    assert_nil StorageSettings.new.form_field("endpoint").value

    assert StorageSettings.new.save({ "endpoint" => endpoint, "endpoint_visibility" => "public" }, actor: @admin)
    assert_equal endpoint, StorageSettings.new.form_field("endpoint").value
    assert_nil Setting.read_integration_value(:tencent_cos, :endpoint)
    assert_equal [ "endpoint" ], Log.last.details.fetch("fields")

    replacement = "https://gateway.example.invalid/s3/v2"
    ENV["TENCENT_COS_ENDPOINT"] = replacement
    assert_nil StorageSettings.new.form_field("endpoint").value
    assert_equal replacement, StorageSettings.new.read("endpoint")
    assert StorageSettings.new.save({ "clear_fields" => [ "endpoint" ] }, actor: @admin)
    assert_equal [ "endpoint" ], Log.last.details.fetch("fields")
    ENV["TENCENT_COS_ENDPOINT"] = endpoint
    assert_nil StorageSettings.new.form_field("endpoint").value
  ensure
    ENV["TENCENT_COS_ENDPOINT"] = previous
  end
end

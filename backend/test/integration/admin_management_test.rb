require "test_helper"

class AdminManagementTest < ActionDispatch::IntegrationTest
  setup do
    @root = Admin.create!(username: "root", role: "super_admin")
    StorageConfiguration.reset!
  end

  test "anonymous requests require login and the username form authenticates" do
    get admins_root_path
    assert_redirected_to new_admin_session_path
    get new_admin_session_path
    assert_response :success
    post admin_session_path, params: { admin: { username: "root", password: "wrong-password" } }
    assert_response :unprocessable_content
    assert Log.where(action: "admin.sign_in", status: "failed").exists?
    login(@root)
    assert_redirected_to admins_root_path
    assert_equal "success", Log.where(action: "admin.sign_in").last.status
    get admins_root_path
    assert_response :success
  end

  test "operators and customer service cannot reach privileged pages or writes" do
    %w[operator customer_service].each do |role|
      admin = Admin.create!(username: role, role: role)
      login(admin)
      get admins_root_path
      assert_response :success
      assert_select "a[href=?]", admins_administrators_path, count: 0
      [ admins_administrators_path, edit_admins_system_settings_storage_path ].each do |path|
        get path
        assert_response :forbidden
      end
      assert_no_difference [ "Admin.count", "Setting.count" ] do
        post admins_administrators_path, params: { administrator: { username: "escalated", role: "super_admin" } }
        assert_response :forbidden
        patch admins_system_settings_storage_path, params: { storage_settings: { service: "local" } }
        assert_response :forbidden
      end
      delete destroy_admin_session_path
    end
  end

  test "super admin creates accounts edits without clearing passwords and retains a usable super admin" do
    login(@root)
    get new_admins_administrator_path
    assert_response :success
    post admins_administrators_path, params: { administrator: { username: "helper", role: "operator", password: "" } }
    assert_redirected_to admins_administrators_path
    helper = Admin.find_by!(username: "helper")
    assert helper.valid_password?("123456")
    patch admins_administrator_path(helper), params: { administrator: { name: "客服同事", role: "customer_service", password: "" } }
    assert_redirected_to admins_administrators_path
    assert helper.reload.valid_password?("123456")
    patch admins_administrator_path(@root), params: { administrator: { enabled: "false" } }
    assert_response :unprocessable_content
    assert @root.reload.enabled?
  end

  test "administrator status and keyword filters narrow the same list" do
    matched = Admin.create!(username: "disabled_helper", role: "operator", enabled: false)
    Admin.create!(username: "enabled_helper", role: "operator")
    Admin.create!(username: "disabled_other", role: "operator", enabled: false)
    login(@root)

    get admins_administrators_path, params: { q: "helper", status: "disabled" }

    assert_response :success
    assert_select "table tbody tr", count: 1 do
      assert_select "td", text: "##{matched.id}"
    end
    assert_select "form input[name=status][value=disabled]"
  end

  test "disabling an account invalidates an already authenticated session" do
    admin = Admin.create!(username: "operator", role: "operator")
    login(admin)
    admin.update!(enabled: false)
    get admins_root_path
    assert_redirected_to new_admin_session_path
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
    assert_redirected_to new_admin_session_path
    assert_equal "failed", Log.where(action: "admin.sign_in").last.status
  end

  test "own password change requires the old password and cannot change role" do
    admin = Admin.create!(username: "operator", role: "operator")
    login(admin)
    patch admins_account_path, params: { account: { current_password: "wrong-password", password: "new-password", password_confirmation: "new-password" } }
    assert_response :unprocessable_content
    assert admin.reload.valid_password?("123456")
    failure = Log.find_by!(action: "admin.password", status: "failed", actor_id: admin.id)
    assert_equal({ "reason" => "账号校验失败" }, failure.details)
    assert_not_includes failure.attributes.to_json, "new-password"
    assert_not_includes failure.attributes.to_json, "wrong-password"
    patch admins_account_path, params: { account: { current_password: "123456", password: "new-password", password_confirmation: "new-password", role: "super_admin" } }
    assert_redirected_to edit_admins_account_path
    assert admin.reload.valid_password?("new-password")
    assert_equal "operator", admin.role
    get admins_root_path
    assert_response :success
  end

  test "super admin password reset invalidates an older session" do
    admin = Admin.create!(username: "operator", role: "operator")
    login(admin)
    assert Admin.update_managed(admin, { password: "reset-password" }, actor: @root)
    get admins_root_path
    assert_redirected_to new_admin_session_path
  end

  test "settings and log pages do not render submitted secrets even after validation failures" do
    login(@root)
    patch admins_system_settings_path, params: { storage_settings: { revision: StorageSettings.new.revision, service: "local", secret_id: "fake-secret-id", secret_key: "fake-secret-key", region: "ap-shanghai", bucket: "test-bucket-123" } }
    assert_redirected_to edit_admins_system_settings_storage_path
    get edit_admins_system_settings_storage_path
    assert_response :success
    assert_select "input[name='storage_settings[secret_key]'][value]", count: 0
    assert_not_includes response.body, "fake-secret-key"
    patch admins_system_settings_storage_path, params: { storage_settings: { revision: StorageSettings.new.revision, secret_key: "another-test-secret", endpoint: "http://unsafe.invalid" } }
    assert_response :unprocessable_content
    assert_select "#sidebar-menu a[aria-current=page][href=?]", edit_admins_system_settings_storage_path
    assert_not_includes response.body, "another-test-secret"
    assert_equal "fake-secret-key", Setting.read_integration_value(:tencent_cos, :secret_key)
    failure = Log.find_by!(action: "storage_settings.update", status: "failed", actor_id: @root.id)
    assert_equal({ "fields" => %w[secret_key endpoint], "reason" => "配置校验失败" }, failure.details)
    get admins_operation_logs_path
    assert_response :success
    get admins_operation_log_path(failure)
    assert_response :success
    assert_not_includes response.body, "fake-secret-key"
    assert_not_includes response.body, "another-test-secret"
  end

  test "malformed storage submissions retain their bad request status and a redacted audit" do
    login(@root)
    patch admins_system_settings_storage_path, params: { storage_settings: "bad-test-secret" }
    assert_response :bad_request
    failure = Log.find_by!(action: "storage_settings.update", actor_id: @root.id, status: "failed")
    assert_equal({ "fields" => [], "reason" => "配置校验失败" }, failure.details)
  end

  test "invalid configured services block storage use but can be repaired from the settings page" do
    login(@root)
    record = Setting.create!(key: "active_storage")
    [ false, 0, "unknown-test-service" ].each do |invalid|
      record.update!(settings: { "service" => invalid })
      get admins_root_path
      assert_response :service_unavailable
      get edit_admins_system_settings_storage_path
      assert_response :success
      assert_select "[data-storage-service] option[selected][disabled][value='']", text: /存储方式无效/
      assert_select "[data-storage-service] option[value=local][selected]", count: 0
      assert_not_includes response.body, "unknown-test-service"
    end
    patch admins_system_settings_storage_path, params: { storage_settings: { revision: StorageSettings.new.revision, service: "local" } }
    assert_redirected_to edit_admins_system_settings_storage_path
    get admins_root_path
    assert_response :success
  end

  test "client refresh failure reports a committed save and retries on the next request" do
    login(@root)
    config = Rails.application.config.active_storage
    original = config.service_configurations
    old_registry = ActiveStorage::Blob.services
    config.service_configurations = { "test-only-private-detail" => {} }
    patch admins_system_settings_storage_path, params: { storage_settings: { revision: StorageSettings.new.revision, secret_key: "saved-test-secret" } }
    assert_redirected_to edit_admins_system_settings_storage_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "配置已保存，存储客户端刷新失败"
    assert_not_includes response.body, "test-only-private-detail"
    assert_not_includes response.body, "saved-test-secret"
    assert_equal "saved-test-secret", Setting.read_integration_value(:tencent_cos, :secret_key)
    saved = Log.find_by!(action: "storage_settings.update", actor_id: @root.id)
    failure = Log.find_by!(action: "storage_settings.refresh", status: "failed", request_id: saved.request_id)
    assert_equal "success", saved.status
    assert_equal({ "reason" => "配置已保存，存储客户端刷新失败" }, failure.details)
    assert_same old_registry, ActiveStorage::Blob.services
    config.service_configurations = original
    get admins_root_path
    assert_response :success
    assert_not_same old_registry, ActiveStorage::Blob.services
  ensure
    config.service_configurations = original if config
    StorageConfiguration.reset!
  end

  test "saving the storage form keeps inherited COS values out of the database" do
    external = {
      "ACTIVE_STORAGE_SERVICE" => "tencent_cos",
      "TENCENT_COS_SECRET_ID" => "test-only-env-id",
      "TENCENT_COS_SECRET_KEY" => "test-only-env-key",
      "TENCENT_COS_REGION" => "ap-shanghai",
      "TENCENT_COS_BUCKET" => "env-bucket-123",
      "TENCENT_COS_ENDPOINT" => "https://cos.ap-shanghai.myqcloud.com"
    }
    previous = external.keys.to_h { |key| [ key, ENV[key] ] }
    ENV.update(external)

    login(@root)
    get edit_admins_system_settings_storage_path
    assert_response :success
    bucket_input = css_select("input[name='storage_settings[bucket]']").first
    assert_nil bucket_input["value"]
    assert_includes bucket_input["placeholder"], "env-bucket-123（ENV）"
    assert_not_includes response.body, "test-only-env-key"

    patch admins_system_settings_storage_path, params: { storage_settings: {
      revision: StorageSettings.new.revision, service: "tencent_cos", bucket: bucket_input["value"].to_s,
      secret_key: "updated-test-only-key"
    } }
    assert_redirected_to edit_admins_system_settings_storage_path
    assert_nil Setting.read_integration_value(:active_storage, :service)
    assert_nil Setting.read_integration_value(:tencent_cos, :bucket)
    assert_equal "updated-test-only-key", Setting.read_integration_value(:tencent_cos, :secret_key)
  ensure
    ENV.update(previous)
    StorageConfiguration.reset!
  end

  private

  def login(admin)
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
  end
end

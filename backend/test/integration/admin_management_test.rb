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
      [ admins_administrators_path, edit_admins_system_settings_path, admins_operation_logs_path ].each do |path|
        get path
        assert_response :forbidden
      end
      assert_no_difference [ "Admin.count", "Setting.count" ] do
        post admins_administrators_path, params: { administrator: { username: "escalated", role: "super_admin" } }
        assert_response :forbidden
        patch admins_system_settings_path, params: { storage_settings: { service: "local" } }
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
    assert_redirected_to edit_admins_system_settings_path
    get edit_admins_system_settings_path
    assert_response :success
    assert_select "input[name='storage_settings[secret_key]'][value]", count: 0
    assert_not_includes response.body, "fake-secret-key"
    patch admins_system_settings_path, params: { storage_settings: { revision: StorageSettings.new.revision, secret_key: "another-test-secret", endpoint: "http://unsafe.invalid" } }
    assert_response :unprocessable_content
    assert_not_includes response.body, "another-test-secret"
    assert_equal "fake-secret-key", Setting.read_integration_value(:tencent_cos, :secret_key)
    get admins_operation_logs_path
    assert_response :success
    get admins_operation_log_path(Log.where(action: "storage_settings.update").last)
    assert_response :success
    assert_not_includes response.body, "fake-secret-key"
  end

  private

  def login(admin)
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
  end
end

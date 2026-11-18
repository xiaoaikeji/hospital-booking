require "test_helper"

class AdminTest < ActiveSupport::TestCase
  test "new accounts use the confirmed default password and role remains explicit" do
    admin = Admin.create!(username: "support", role: "customer_service")
    assert admin.valid_password?("123456")
    assert_not admin.super_admin?
    assert_equal "客服", admin.role_name
  end

  test "last enabled super admin cannot be disabled or demoted" do
    admin = Admin.create!(username: "root", role: "super_admin")
    assert_not Admin.update_managed(admin, { enabled: false }, actor: admin)
    assert_not Admin.update_managed(admin, { role: "operator" }, actor: admin)
    assert admin.reload.enabled?
    assert admin.super_admin?
    replacement = Admin.create!(username: "replacement", role: "super_admin")
    assert Admin.update_managed(admin, { enabled: false }, actor: replacement)
    assert_not admin.reload.active_for_authentication?
  end

  test "failed success audit rolls back the account edit and records a safe failure" do
    admin = Admin.create!(username: "root", role: "super_admin")
    Log.connection.add_check_constraint(:logs, "action <> 'admin.update' OR status <> 'success'",
      name: "test_reject_account_success_audit")
    assert_difference "Log.count", 1 do
      assert_not Admin.update_managed(admin, { password: "changed-pass" }, actor: admin)
    end
    assert admin.reload.valid_password?(Admin::DEFAULT_PASSWORD)
    failure = Log.find_by!(target_id: admin.id, action: "admin.update", status: "failed")
    assert_equal({ "reason" => "数据库写入失败" }, failure.details)
    assert_not_includes failure.attributes.to_json, "changed-pass"
  end

  test "password changes are audited without the password and logs are append only" do
    admin = Admin.create!(username: "root", role: "super_admin")
    assert Admin.update_managed(admin, { password: "changed-pass", password_confirmation: "changed-pass" }, actor: admin)
    log = Log.last
    assert_includes log.details.fetch("fields"), "password"
    assert_not_includes log.attributes.to_json, "changed-pass"
    assert_raises(ActiveRecord::ReadOnlyRecord) { log.update!(status: "failed") }
  end
end

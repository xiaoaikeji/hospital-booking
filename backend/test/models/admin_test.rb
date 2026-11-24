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

  test "blank_password? and default_password? detect ASCII and Unicode whitespace uniformly" do
    [ nil, "", "      ", "\t\n\r ", "\u00A0" * 6, "\u3000" * 6, "\u2003" * 6, "\u200B" * 6, "\uFEFF" * 6 ].each do |sample|
      assert Admin.blank_password?(sample), "expected #{sample.inspect} to be treated as blank"
    end

    assert_not Admin.blank_password?("Strong#Pass1")
    assert Admin.default_password?(Admin::DEFAULT_PASSWORD)
    assert Admin.default_password?("\u3000#{Admin::DEFAULT_PASSWORD}\u3000")
    assert_not Admin.default_password?("Strong#Pass1")
  end

  test "explicit password mode and production env reject Unicode blank passwords without falling back to default" do
    [ "", "      ", "\u3000" * 6, "\u00A0" * 6, "\u200B" * 6, "\u3000#{Admin::DEFAULT_PASSWORD}\u3000" ].each_with_index do |bad_pass, idx|
      admin = Admin.new(
        username: "explicit_bad_#{idx}",
        password: bad_pass,
        role: "super_admin",
        require_explicit_password: true
      )
      assert_no_difference "Admin.count" do
        assert_not admin.save
      end
      assert_not admin.valid_password?(Admin::DEFAULT_PASSWORD)
      assert_predicate admin.errors[:password], :any?
    end

    original_env = Rails.env
    Rails.env = ActiveSupport::EnvironmentInquirer.new("production")
    assert_no_difference "Admin.count" do
      prod_admin = Admin.create(username: "prod_unicode_blank", password: "\u3000" * 6, role: "super_admin")
      assert_not prod_admin.persisted?
      assert_predicate prod_admin.errors[:password], :any?
    end
  ensure
    Rails.env = original_env if original_env
  end

  test "production super admins need a nondefault password on creation, promotion and password changes" do
    original_env = Rails.env
    Rails.env = ActiveSupport::EnvironmentInquirer.new("production")

    [ nil, Admin::DEFAULT_PASSWORD ].each do |password|
      admin = Admin.create(username: "new_super_admin", role: "super_admin", password:)
      assert_not admin.persisted?
      assert_predicate admin.errors[:password], :any?
    end

    operator = Admin.create!(username: "promotion_candidate", role: "operator")
    assert operator.valid_password?(Admin::DEFAULT_PASSWORD)
    assert_not operator.update(role: "super_admin")
    assert_predicate operator.errors[:password], :any?
    assert_equal "operator", operator.reload.role

    password = "a-new-test-only-password"
    assert operator.update(role: "super_admin", password:)
    assert_not operator.update(password: Admin::DEFAULT_PASSWORD)
    assert operator.reload.valid_password?(password)
    assert operator.update(name: "Promoted admin")
  ensure
    Rails.env = original_env
  end
end

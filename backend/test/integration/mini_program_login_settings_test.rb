require "test_helper"

class MiniProgramLoginSettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @root = Admin.create!(username: "settings_root", role: "super_admin")
    sign_in @root
  end

  test "the hospital phone policy is versioned, audited and preserves unrelated settings" do
    row = Setting.create!(key: "appointment", settings: { "other" => 1 })
    revision = edit_revision(edit_admins_system_settings_appointment_path)
    assert_select "#sidebar-menu a[href=?]", edit_admins_system_settings_appointment_path
    patch admins_system_settings_appointment_path, params: { appointment: { revision: revision, require_mobile_auth: "1" } }
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal({ "other" => 1, "require_mobile_auth" => true }, row.reload.settings)
    assert_audit "appointment.phone_policy", "success", row, "require_mobile_auth"

    patch admins_system_settings_appointment_path, params: { appointment: { revision: revision, require_mobile_auth: "0" } }
    assert_response :unprocessable_content
    assert_select "[role=alert]", /配置已变化/
    assert_equal true, row.reload.settings.fetch("require_mobile_auth")
    assert_audit "appointment.phone_policy", "failed", row, "require_mobile_auth"

    revision = edit_revision(edit_admins_system_settings_appointment_path)
    patch admins_system_settings_appointment_path, params: { appointment: { revision: revision, require_mobile_auth: "0" } }
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal false, row.reload.settings.fetch("require_mobile_auth")
  end

  test "only registered WeChat mini programs can be assigned and departures refresh UnionIDs without changing user ownership" do
    a, b, c = %w[share_a share_b share_c].map { |appid| App.create!(provider: "wechat", appid: appid) }
    official = App.create!(provider: "wechat", app_type: "official_account", appid: "official_only")
    other = App.create!(provider: "douyin", appid: "douyin_only")
    base = { a.appid => "1", b.appid => "1", c.appid => "0" }
    revision = edit_revision(edit_admins_user_sharing_path)
    assert_select "#sidebar-menu a[href=?]", edit_admins_user_sharing_path
    assert_select "form select", count: 3
    [ official, other ].each do |app|
      assert_select "form select[name=?]", "sharing[memberships][#{app.appid}]", count: 0
      save_groups(revision, base.merge(app.appid => "1"))
      assert_response :unprocessable_content
      assert_nil Setting.find_by(key: "wechat")
    end
    save_groups(revision, base)
    assert_redirected_to edit_admins_user_sharing_path
    row = Setting.find_by!(key: "wechat")
    assert_equal [ [ a.appid, b.appid ] ], row.settings.fetch("unionid_app_groups")
    assert_audit "app.user_sharing", "success", row, "unionid_app_groups"
    save_groups(revision, base.transform_values { "0" })
    assert_response :unprocessable_content
    assert_audit "app.user_sharing", "failed", row, "unionid_app_groups"
    refute b.destroy
    a_binding, b_binding = [ a, b ].map do |app|
      UserApp.create!(app: app, user: User.create!(platform: "wechat"), openid: "known", unionid: "from-first-platform")
    end
    session = MiniProgramSession.issue!(b_binding)[:token]
    c_binding = UserApp.create!(app: c, user: User.create!(platform: "wechat"), openid: "independent", unionid: "from-unverified-platform")
    save_groups(edit_revision(edit_admins_user_sharing_path), base.merge(b.appid => "2", c.appid => "2"))
    assert_redirected_to edit_admins_user_sharing_path
    assert_equal "from-first-platform", a_binding.reload.unionid
    assert_nil b_binding.reload.unionid
    assert_nil c_binding.reload.unionid
    assert_equal b_binding, MiniProgramSession.new(b, session).identity
    assert_equal [ [ a.appid ], [ b.appid, c.appid ] ], row.reload.settings.fetch("unionid_app_groups")
  end

  test "operators and customer service cannot open, see or submit either setting" do
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: role, role: role)
      get admins_root_path
      [ edit_admins_system_settings_appointment_path, edit_admins_user_sharing_path ].each do |path|
        assert_select "#sidebar-menu a[href=?]", path, count: 0
      end
      assert_no_difference [ "Setting.count", "Log.where(action: %w[appointment.phone_policy app.user_sharing]).count" ] do
        [ edit_admins_system_settings_appointment_path, edit_admins_user_sharing_path ].each do |path|
          get path
          assert_response :forbidden
        end
        patch admins_system_settings_appointment_path, params: { appointment: { require_mobile_auth: "1" } }
        assert_response :forbidden
        save_groups("ignored", { "unknown" => "1" })
        assert_response :forbidden
      end
    end
  end

  private

  def edit_revision(path)
    get path
    assert_response :success
    css_select("form input[name$='[revision]']").to_a.sole["value"]
  end

  def save_groups(revision, memberships)
    patch admins_user_sharing_path, params: { sharing: { revision: revision, memberships: memberships } }
  end

  def assert_audit(action, status, target, field)
    log = Log.operations_visible_to(@root).where(action: action, status: status, actor_type: "Admin", actor_id: @root.id,
      target_type: "Setting", target_id: target.id).last!
    assert_equal [ field ], log.details.fetch("fields")
  end
end

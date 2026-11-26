require "test_helper"

class MiniProgramLoginSettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @root = Admin.create!(username: "settings_root", role: "super_admin")
    sign_in @root
  end

  test "a notice is public, participates in the appointment settings revision, and clears without changing either switch" do
    row = Setting.create!(key: "appointment", settings: { "require_mobile_auth" => true, "booking_enable_evening" => false })
    app = App.create!(provider: "wechat", appid: "notice-demo", status: "active")
    config_path = api_app_configuration_path(app.provider, app.appid)
    revision = edit_revision(edit_admins_system_settings_appointment_path)
    notice = "请提前到院\n携带有效证件"
    input = { revision: revision, require_mobile_auth: "1", booking_enable_evening: "0", booking_notice: notice }

    patch admins_system_settings_appointment_path, params: { appointment: input.merge(booking_enable_evening: "invalid") }
    assert_response :unprocessable_content
    assert_not row.reload.settings.key?("booking_notice")

    patch admins_system_settings_appointment_path, params: { appointment: input }
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_audit "appointment.update", "success", row, "booking_notice"
    get config_path
    assert_equal({ "booking_notice" => notice }, response.parsed_body.fetch("appointment"))

    patch admins_system_settings_appointment_path, params: { appointment: input.merge(require_mobile_auth: "0", booking_notice: "") }
    assert_response :unprocessable_content
    assert_equal [ true, false, notice ], row.reload.settings.values_at("require_mobile_auth", "booking_enable_evening", "booking_notice")

    patch admins_system_settings_appointment_path, params: {
      appointment: input.merge(revision: AppointmentSettings.new.revision, booking_notice: "")
    }
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal({ "require_mobile_auth" => true, "booking_enable_evening" => false }, row.reload.settings)
    assert_audit "appointment.update", "success", row, "booking_notice"
    get config_path
    assert_nil response.parsed_body.dig("appointment", "booking_notice")
  end

  test "appointment settings save both switches together, reject stale or invalid values and audit actual changes" do
    row = Setting.create!(key: "appointment", settings: { "other" => 1 })
    revision = edit_revision(edit_admins_system_settings_appointment_path)
    assert_select "#sidebar-menu a[href=?]", edit_admins_system_settings_appointment_path
    assert_select "form.card[action=?]", admins_system_settings_appointment_path, count: 1 do
      assert_select "input[type=checkbox][name='appointment[require_mobile_auth]']"
      assert_select "input[type=checkbox][name='appointment[booking_enable_evening]']"
      assert_select "button[type=submit]", text: /保存设置/, count: 1
    end

    save_appointment(revision, phone: "1", night: "1")
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal({ "other" => 1, "require_mobile_auth" => true, "booking_enable_evening" => true }, row.reload.settings)
    assert_audit "appointment.update", "success", row, "require_mobile_auth", "booking_enable_evening"

    revision = edit_revision(edit_admins_system_settings_appointment_path)
    assert_no_difference -> { Log.where(action: "appointment.update", status: "success").count } do
      save_appointment(revision, phone: "0", night: "invalid")
    end
    assert_response :unprocessable_content
    assert_equal [ true, true ], row.reload.settings.values_at("require_mobile_auth", "booking_enable_evening")
    assert_audit "appointment.update", "failed", row, "require_mobile_auth", "booking_enable_evening"

    save_appointment(revision, phone: "1", night: "0")
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal [ true, false ], row.reload.settings.values_at("require_mobile_auth", "booking_enable_evening")
    assert_audit "appointment.update", "success", row, "booking_enable_evening"

    save_appointment(revision, phone: "0", night: "0")
    assert_response :unprocessable_content
    assert_select "[role=alert]", /配置已变化/
    assert_equal [ true, false ], row.reload.settings.values_at("require_mobile_auth", "booking_enable_evening")

    revision = edit_revision(edit_admins_system_settings_appointment_path)
    save_appointment(revision, phone: "0", night: "0")
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal({ "other" => 1, "require_mobile_auth" => false, "booking_enable_evening" => false }, row.reload.settings)
    assert_audit "appointment.update", "success", row, "require_mobile_auth"
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

  test "the map key is encrypted, replaceable and clearable with a field-only audit" do
    path = edit_admins_system_settings_map_path
    revision = edit_revision(path)
    first, second = SecureRandom.hex, SecureRandom.hex
    patch admins_system_settings_map_path, params: { map: { ak: first, revision: revision } }
    assert_redirected_to path
    row = Setting.find_by!(key: "baidu_map")
    assert_predicate row.settings.fetch("ak").fetch("ciphertext"), :present?
    refute_includes row.settings.to_json, first
    newer = edit_revision(path)
    assert_select "#map_ak[data-write-only]:not([value])"
    assert_not_includes response.body, first
    patch admins_system_settings_map_path, params: { map: { ak: second, revision: revision } }
    assert_response :unprocessable_content
    [ first, second ].each { |key| assert_not_includes response.body, key }
    patch admins_system_settings_map_path, params: { map: { ak: second, revision: newer } }
    assert_redirected_to path
    assert_equal second, MapSettings.new.key
    patch admins_system_settings_map_path, params: { map: { clear_key: "1", revision: MapSettings.new.revision } }
    assert_redirected_to path
    refute row.reload.settings.key?("ak")
    Log.where(action: "map_settings.update").each do |event|
      assert_equal %w[ak], event.details.fetch("fields")
      [ first, second ].each { |key| refute_includes event.details.to_json, key }
    end
  end

  test "operators and customer service cannot open, see or submit login and map settings" do
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: role, role: role)
      get admins_root_path
      [ edit_admins_system_settings_appointment_path, edit_admins_user_sharing_path, edit_admins_system_settings_map_path ].each do |path|
        assert_select "#sidebar-menu a[href=?]", path, count: 0
      end
      assert_no_difference [ "Setting.count", "Log.where(action: %w[appointment.update app.user_sharing]).count" ] do
        [ edit_admins_system_settings_appointment_path, edit_admins_user_sharing_path, edit_admins_system_settings_map_path ].each do |path|
          get path
          assert_response :forbidden
        end
        save_appointment("ignored", phone: "1", night: "1")
        assert_response :forbidden
        save_groups("ignored", { "unknown" => "1" })
        assert_response :forbidden
        patch admins_system_settings_map_path, params: { map: { ak: SecureRandom.hex } }
        assert_response :forbidden
      end
    end
  end

  private

  def edit_revision(path)
    get path
    assert_response :success
    css_select("form.card input[name$='[revision]']").to_a.sole["value"]
  end

  def save_groups(revision, memberships)
    patch admins_user_sharing_path, params: { sharing: { revision: revision, memberships: memberships } }
  end

  def save_appointment(revision, phone:, night:)
    patch admins_system_settings_appointment_path, params: {
      appointment: { revision: revision, require_mobile_auth: phone, booking_enable_evening: night }
    }
  end

  def assert_audit(action, status, target, *fields)
    log = Log.operations_visible_to(@root).where(action: action, status: status, actor_type: "Admin", actor_id: @root.id,
      target_type: "Setting", target_id: target.id).last!
    assert_equal fields, log.details.fetch("fields")
  end
end

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
    assert_equal notice, response.parsed_body.dig("appointment", "booking_notice")

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

  test "the four appointment rules default on older installations and save alongside existing values" do
    notice = "请提前到院\n携带有效证件"
    existing = { "require_mobile_auth" => true, "booking_enable_evening" => true, "booking_notice" => notice }
    row = Setting.create!(key: "appointment", settings: existing)
    app = App.create!(provider: "wechat", appid: "appointment-rules-demo", status: "active")
    config_path = api_app_configuration_path(app.provider, app.appid)
    defaults = { "show_unscheduled_doctors" => true, "require_booking_remark" => false,
      "display_free_fee_when_fee_is_zero" => true, "display_hospital_address" => false }
    revision = edit_revision(edit_admins_system_settings_appointment_path)
    defaults.each do |field, enabled|
      assert_select "input[type=checkbox][name='appointment[#{field}]']", count: 1 do |inputs|
        assert_equal enabled, inputs.first.key?("checked")
      end
    end
    get config_path
    assert_equal defaults.merge("booking_notice" => notice), response.parsed_body.fetch("appointment")

    updated = defaults.transform_values { |enabled| !enabled }
    input = updated.transform_values { |enabled| enabled ? "1" : "0" }.merge(
      revision: revision, require_mobile_auth: "1", booking_enable_evening: "1", booking_notice: notice
    )
    patch admins_system_settings_appointment_path, params: { appointment: input.merge("display_hospital_address" => "invalid") }
    assert_response :unprocessable_content
    assert_equal existing, row.reload.settings

    patch admins_system_settings_appointment_path, params: { appointment: input }
    assert_redirected_to edit_admins_system_settings_appointment_path
    assert_equal existing.merge(updated), row.reload.settings
    assert_audit "appointment.update", "success", row, *updated.keys
    get config_path
    assert_equal updated.merge("booking_notice" => notice), response.parsed_body.fetch("appointment")

    patch admins_system_settings_appointment_path, params: { appointment: input.merge(require_mobile_auth: "0") }
    assert_response :unprocessable_content
    assert_select "[role=alert]", /配置已变化/
    assert_equal existing.merge(updated), row.reload.settings
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

  test "time-slot settings validate all windows and preserve the per-slot limit when switched off" do
    path = edit_admins_system_settings_appointment_path
    revision = edit_revision(path)
    assert_select "#appointment_booking_by_time_slot:not([checked])"
    assert_select "#appointment_max_bookings_per_slot[value='5'][disabled]"
    assert_select "#appointment_booking_morning_begin_at option[selected][value='08:00']"
    assert_select "#appointment_booking_afternoon_begin_at option[selected][value='12:00']"
    assert_select "#appointment_booking_evening_end_at option[selected][value='21:00']"

    input = { revision:, require_mobile_auth: "0", booking_enable_evening: "0", booking_by_time_slot: "1",
      max_bookings_per_slot: "6", booking_morning_end_at: "11:30", booking_afternoon_begin_at: "13:30" }
    [ [ { max_bookings_per_slot: "0" }, AppointmentSettings::INVALID_SLOT_CAPACITY ],
      [ { booking_morning_end_at: "11:15" }, AppointmentSettings::INVALID_TIME ],
      [ { booking_morning_begin_at: "11:30" }, AppointmentSettings::INVALID_WINDOW ],
      [ { booking_afternoon_end_at: "17:30" }, AppointmentSettings::OVERLAPPING_WINDOWS ] ].each do |invalid, reason|
      patch admins_system_settings_appointment_path, params: { appointment: input.merge(invalid) }
      assert_response :unprocessable_content
      refute AppointmentSettings.new.time_slot_booking?
      assert_equal "12:00", AppointmentSettings.new.shift_time("booking_morning_end_at")
      failure = Log.operations_visible_to(@root).where(action: "appointment.update", status: "failed").last!
      get admins_operation_log_path(failure)
      assert_response :success
      assert_select "dd", text: reason
    end

    historical_failure = Log.create!(category: "settings", source: "admin", action: "appointment.update", status: "failed",
      actor_type: "Admin", actor_id: @root.id, details: { "reason" => "unrecognized-text-fixture", "secret_value" => "hidden-value-fixture" })
    get admins_operation_log_path(historical_failure)
    assert_response :success
    assert_not_includes response.body, "unrecognized-text-fixture"
    assert_not_includes response.body, "hidden-value-fixture"

    patch admins_system_settings_appointment_path, params: { appointment: input }
    assert_redirected_to path
    row = Setting.find_by!(key: "appointment")
    assert_audit "appointment.update", "success", row, "booking_by_time_slot", "max_bookings_per_slot",
      "booking_morning_end_at", "booking_afternoon_begin_at"
    follow_redirect!
    assert_select "#appointment_booking_by_time_slot[checked]"
    assert_select "#appointment_max_bookings_per_slot[value='6']:not([disabled])"

    patch admins_system_settings_appointment_path, params: {
      appointment: { revision:, require_mobile_auth: "0", booking_enable_evening: "0", booking_notice: "旧表单的须知" }
    }
    assert_response :unprocessable_content
    assert_select "[role=alert]", /配置已变化/
    assert_equal [ 6, nil ], row.reload.settings.values_at("max_bookings_per_slot", "booking_notice")

    patch admins_system_settings_appointment_path, params: {
      appointment: input.except(:max_bookings_per_slot).merge(revision: AppointmentSettings.new.revision, booking_by_time_slot: "0")
    }
    assert_redirected_to path
    assert_equal [ false, 6, "11:30", "13:30" ],
      row.reload.settings.values_at("booking_by_time_slot", "max_bookings_per_slot", "booking_morning_end_at", "booking_afternoon_begin_at")
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

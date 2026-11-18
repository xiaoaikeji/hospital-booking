require "test_helper"

class AdminSettingsPermissionsTest < ActionDispatch::IntegrationTest
  setup do
    @storage = Setting.create!(key: "tencent_cos", settings: { "region" => "ap-shanghai" })
    @appearance = Setting.create!(key: "appearance", settings: { "navbar_style" => "floating" })
    @other = Admin.create!(username: "other_admin", role: "operator", appearance_overrides: { "theme_primary" => "red" })
  end

  test "super admin sees the settings menus and can edit global settings and clear storage" do
    admin = sign_in_role("super_admin")
    assert_select "#sidebar-menu .dropdown-toggle", text: /系统设置/
    assert_select "header nav a[href=?]", edit_admins_system_settings_storage_path, text: /系统设置/
    assert_select "header a.dropdown-item[href=?]", edit_admins_system_settings_storage_path, text: "系统设置"
    pages = [ edit_admins_system_settings_storage_path, edit_admins_system_settings_appearance_path ]
    pages.each { |path| assert_select "#sidebar-menu a[href=?]", path }
    check_personal_appearance(admin)

    (pages + [ edit_admins_system_settings_path ]).each do |path|
      get path
      assert_response :success
      pages.each { |tab| assert_select "nav[aria-label='系统设置'] a[href=?]", tab }
    end
    assert_no_changes -> { Admin.order(:id).pluck(:id, :appearance_overrides) } do
      patch admins_system_settings_appearance_path, params: { revision: AppearanceSettings.new.revision, appearance: { navbar_style: "default" } }
      assert_redirected_to edit_admins_system_settings_appearance_path
      assert_empty @appearance.reload.settings
      patch admins_system_settings_storage_path, params: { storage_settings: { revision: StorageSettings.new.revision, region: "ap-beijing" } }
      assert_redirected_to edit_admins_system_settings_storage_path
      assert_equal "ap-beijing", @storage.reload.settings.fetch("region")
      patch admins_system_settings_path, params: { storage_settings: { revision: StorageSettings.new.revision, clear_fields: StorageSettings::FIELDS.keys } }
      assert_redirected_to edit_admins_system_settings_storage_path
      assert_empty @storage.reload.settings
    end
  end

  %w[operator customer_service].each do |role|
    test "#{role} has only personal appearance access across current and legacy settings routes" do
      admin = sign_in_role(role)
      assert_select "#sidebar-menu a, header a", text: /系统设置/, count: 0
      assert_select "a[href^='/admins/system_settings']", count: 0
      check_personal_appearance(admin)

      assert_no_changes -> { Setting.order(:key).pluck(:key, :settings) } do
        [ edit_admins_system_settings_storage_path, edit_admins_system_settings_path, edit_admins_system_settings_appearance_path ].each do |path|
          get path
          assert_response :forbidden
          assert_select "nav[aria-label='系统设置'], form[action^='/admins/system_settings']", count: 0
        end
        [ admins_system_settings_storage_path, admins_system_settings_path ].each do |path|
          revision = StorageSettings.new.revision
          patch path, params: { storage_settings: { revision: revision, region: "ap-beijing" } }
          assert_response :forbidden
          patch path, params: { storage_settings: { revision: revision, clear_fields: StorageSettings::FIELDS.keys } }
          assert_response :forbidden
        end
        patch admins_system_settings_appearance_path, params: { revision: AppearanceSettings.new.revision, appearance: { navbar_style: "default" } }
        assert_response :forbidden
      end
    end
  end

  test "an invalid storage configuration cannot preempt the global appearance permission check" do
    sign_in_role("operator")
    Setting.create!(key: "active_storage", settings: { "service" => false })
    get edit_admins_system_settings_appearance_path
    assert_response :forbidden
  end

  private

  def sign_in_role(role)
    admin = Admin.create!(username: role, role: role)
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
    assert_redirected_to admins_root_path
    follow_redirect!
    assert_response :success
    admin
  end

  def check_personal_appearance(admin)
    assert_select "button.btn-floating[data-bs-target='#theme-settings']"
    assert_select "#theme-settings[data-url=?] #reset-theme-settings", admins_personal_appearance_path
    revision = css_select("#theme-settings").first["data-revision"]
    assert_no_changes -> { [ @appearance.reload.settings, @other.reload.appearance_overrides ] } do
      patch admins_personal_appearance_path, params: { admin_id: @other.id, revision: revision, appearance: { theme_primary: "purple" } }, as: :json
      assert_response :success
      assert_equal({ "theme_primary" => "purple" }, admin.reload.appearance_overrides)
      assert_equal({ "theme_primary" => "red" }, @other.reload.appearance_overrides)
      delete admins_personal_appearance_path, params: { admin_id: @other.id, revision: response.parsed_body.fetch("revision") }, as: :json
      assert_response :success
      assert_empty admin.reload.appearance_overrides
      assert_equal "floating", response.parsed_body.fetch("values").fetch("navbar_style")
    end
  end
end

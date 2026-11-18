require "test_helper"

class AdminAppearanceTest < ActionDispatch::IntegrationTest
  setup do
    @a = Admin.create!(username: "appearance_a", role: "operator")
    @b = Admin.create!(username: "appearance_b", role: "super_admin")
  end

  test "personal color follows the account while navigation follows the current global default" do
    login(@a)
    patch admins_personal_appearance_path, params: { appearance: { "theme_primary" => "purple" },
      admin_id: @b.id, revision: panel_revision }, as: :json
    assert_response :success
    assert_equal({ "theme_primary" => "purple" }, @a.reload.appearance_overrides)
    assert_empty @b.reload.appearance_overrides
    stale_account_revision = panel_revision
    get edit_admins_system_settings_appearance_path
    assert_response :forbidden
    patch admins_system_settings_appearance_path, params: { appearance: { navbar: "sticky" }, revision: AppearanceSettings.new.revision }
    assert_response :forbidden

    delete destroy_admin_session_path
    login(@b)
    get admins_root_path
    assert_select "html[data-bs-theme-primary]", count: 0
    patch admins_personal_appearance_path, params: { revision: stale_account_revision, appearance: { layout: "boxed" } }, as: :json
    assert_response :unprocessable_content
    assert_empty @b.reload.appearance_overrides
    get edit_admins_system_settings_appearance_path
    assert_response :success
    patch admins_system_settings_appearance_path, params: { revision: css_select("input[name=revision]").first["value"],
      appearance: { "navbar_style" => "floating" } }
    assert_redirected_to edit_admins_system_settings_appearance_path
    follow_redirect!
    assert_select "html[data-bs-navbar-style=floating]"
    assert_select "html[data-bs-theme-primary]", count: 0

    # 全新会话模拟另一台设备，服务端首屏已合并账号覆盖。
    reset!
    login(@a)
    get admins_root_path
    assert_select "html[data-bs-navbar-style=floating][data-bs-theme-primary=purple]"
    delete admins_personal_appearance_path, params: { revision: panel_revision }, as: :json
    assert_response :success
    assert_empty @a.reload.appearance_overrides
    get admins_root_path
    assert_select "html[data-bs-navbar-style=floating]"
    assert_select "html[data-bs-theme-primary]", count: 0
    assert_equal({ "navbar_style" => "floating" }, Setting.find_by!(key: "appearance").settings)
  end

  test "consecutive color changes and reset use the preceding save response without reloading" do
    login(@a)
    revision = panel_revision
    %w[red orange purple].each do |color|
      patch admins_personal_appearance_path, params: { revision: revision, appearance: { theme_primary: color } }, as: :json
      assert_response :success
      assert_equal({ "theme_primary" => color }, @a.reload.appearance_overrides)
      revision = response.parsed_body.fetch("revision")
    end
    delete admins_personal_appearance_path, params: { revision: revision }, as: :json
    assert_response :success
    assert_empty @a.reload.appearance_overrides
  end

  test "invalid options and outdated requests leave the last successful settings intact" do
    login(@a)
    revision = panel_revision
    patch admins_personal_appearance_path, params: { revision: revision, appearance: { layout: "boxed", "theme_primary" => "invalid" } }, as: :json
    assert_response :unprocessable_content
    assert_empty @a.reload.appearance_overrides
    patch admins_personal_appearance_path, params: { revision: revision, appearance: { layout: "boxed", "theme_primary" => "cyan" } }, as: :json
    assert_response :success
    delete admins_personal_appearance_path, params: { revision: revision }, as: :json
    assert_response :unprocessable_content
    assert_equal "boxed", @a.reload.appearance_overrides.fetch("layout")
    patch admins_personal_appearance_path, params: { revision: panel_revision, appearance: { layout: nil } }, as: :json
    assert_response :success
    assert_equal({ "theme_primary" => "cyan" }, @a.reload.appearance_overrides)
    log = Log.where(action: "personal_appearance.update", status: "success").last
    assert_equal [ "layout" ], log.details.fetch("fields")
    assert_equal @a.id, log.actor_id
  end

  private

  def login(admin)
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
    assert_redirected_to admins_root_path
  end

  def panel_revision
    get admins_root_path
    assert_response :success
    css_select("#theme-settings").first["data-revision"]
  end
end

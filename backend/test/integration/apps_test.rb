require "test_helper"
require_relative "../support/wechat_http_test"

class AppsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  setup { install_wechat_stubs }
  teardown { remove_wechat_stubs }

  test "未配置第三方平台时打开微信应用详情无需加载微信客户端" do
    sign_in Admin.create!(username: "boss", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxDetail")
    @previous_env.each_key { |name| ENV.delete(name) }

    stub_const(Object, :Wechat, Module.new) do
      get admins_app_path(app)
      assert_response :success
      assert_select "h2", "应用资料"
      assert_select "[role='status']", /请配置第三方平台/
    end
  end

  test "密钥解密失败时保留编辑页布局并标记字段" do
    sign_in Admin.create!(username: "credential_admin", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxDamaged")
    App.where(id: app.id).update_all("appsecret = 'damaged-ciphertext'")

    get edit_admins_app_path(app)

    assert_response :unprocessable_content
    assert_select "h1", "编辑应用"
    assert_select ".badge.bg-danger-lt", "解密失败"
    assert_select "#app_appsecret[disabled][aria-describedby='appsecret-error']"
    assert_select "#appsecret-error.invalid-feedback", /核对加密主密钥/
    assert_not_includes response.body, "damaged-ciphertext"
  end

  test "管理页面及写操作仅向超管开放" do
    app = App.create!(provider: "wechat", appid: "wxA", appsecret: "demo-only")
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: role, role: role)
      get admins_root_path
      assert_select "a[href=?]", admins_apps_path, count: 0
      [ admins_apps_path, admins_app_path(app), new_admins_app_path, edit_admins_app_path(app) ].each do |url|
        get url
        assert_response :forbidden
        assert_not_includes response.body, "demo-only"
      end
      post admins_apps_path
      assert_response :forbidden
      patch admins_app_path(app)
      assert_response :forbidden
      delete admins_app_path(app)
      assert_response :forbidden
    end
  end

  test "平台授权可独立校验启用，当前审核与新体验版分开，筛选后返回原列表" do
    admin = Admin.create!(username: "app_scope_admin", role: "super_admin")
    sign_in admin
    app = App.create!(provider: "wechat", appid: "wxManaged", nickname: "门诊")
    auth = app.create_app_authorization!(refresh_token: "test-refresh")
    Rails.cache.write("apps/#{app.id}/channel_token", { value: "managed", revision: auth.updated_at.to_f })
    patch admins_app_path(app), params: { app: { status: "active", revision: AppConfiguration.new(app).revision } }
    assert_redirected_to admins_app_path(app)
    assert_equal "active", app.reload.status
    first = app.mini_program_releases.create!(status: "uploaded", template_id: "1", version: "1.1", description: "旧版本", operator: admin)
    app.mini_program_audits.create!(mini_program_release: first, version: "1.1", description: "审核说明", operator: admin, previous_status: "active", status: "pending")
    trial = app.mini_program_releases.create!(status: "uploaded", template_id: "2", version: "1.2", description: "体验版", operator: admin, current_build: true)
    get admins_app_path(app), params: { list: { app_type: "mini_program", q: "门诊" } }
    assert_select "dd", text: "1.1 · 审核中"
    assert_select "dd", text: "1.2"
    assert_select "[data-qrcode-panel] [data-code-src=?]", trial_admins_app_release_path(app, trial)
    assert_select "a[href=?]", admins_apps_path(app_type: "mini_program", q: "门诊"), text: /返回列表/
    post admins_apps_path, params: { app: { provider: "douyin", app_type: "official_account", appid: "invalid" } }
    assert_response :unprocessable_content
    assert_select "#app_type-error", text: /抖音仅支持小程序/
  end

  test "启用要求平台验证成功，清除覆盖后恢复本应用部署密钥" do
    sign_in Admin.create!(username: "boss", role: "super_admin")
    key = "MINI_APP_WECHAT_wxDemo_APPSECRET"
    ENV[key] = "fallback-demo"
    app = App.create!(provider: "wechat", appid: "wxDemo", appsecret: "database-demo")
    change = ->(values) { patch admins_app_path(app), params: { app: values.merge(revision: AppConfiguration.new(app.reload).revision) } }
    @stubs.post("/cgi-bin/stable_token") { raise Faraday::TimeoutError }
    change.call(status: "active")
    assert_response :unprocessable_content
    assert_includes response.body, "平台暂不可达"
    assert_equal "disabled", app.reload.status
    @stubs.post("/cgi-bin/stable_token") do |env|
      assert_equal "fallback-demo", JSON.parse(env.body)["secret"]
      response_for(access_token: "demo-stable")
    end
    change.call(status: "active", clear_secret: "1")
    assert_equal "active", app.reload.status
    assert_nil app.appsecret
    assert_equal "已验证", AppConfiguration.new(app).credential_status
    get edit_admins_app_path(app)
    assert_select "input[name='app[appsecret]'][value='fallback-demo']"
  ensure
    ENV.delete(key)
  end

  test "来源、并发轮换、身份与删除审计按应用隔离" do
    sign_in Admin.create!(username: "boss", role: "super_admin")
    key = "MINI_APP_WECHAT_wxB_APPSECRET"
    ENV[key] = "env-demo"
    post admins_apps_path, params: { app: { provider: "wechat", appid: "wxA", appsecret: "demo-a" } }
    a = App.find_by!(appid: "wxA")
    b = App.create!(provider: "wechat", appid: "wxB")
    get admins_apps_path
    assert_response :success
    get admins_app_path(a)
    assert_response :success
    get edit_admins_app_path(b)
    assert_select "input[name='app[appsecret]'][value='env-demo']"
    assert_includes response.body, "环境变量"
    revision = AppConfiguration.new(b).revision
    patch admins_app_path(b), params: { app: { appid: "wxA", nickname: "B", revision: revision, appsecret: "env-demo" } }
    assert_redirected_to admins_app_path(b)
    assert_nil b.reload.appsecret
    assert_equal "wxB", b.appid
    revision = AppConfiguration.new(b).revision
    ENV[key] = "new-demo"
    patch admins_app_path(b), params: { app: { revision: revision, appsecret: "env-demo" } }
    assert_response :unprocessable_content
    assert_nil b.reload.appsecret
    [ a, b ].each { |app| Rails.cache.write("apps/#{app.id}/channel_token", "cached") }
    patch admins_app_path(a), params: { app: { revision: AppConfiguration.new(a).revision, appsecret: "rotated-demo" } }
    assert_nil Rails.cache.read("apps/#{a.id}/channel_token")
    assert_equal "cached", Rails.cache.read("apps/#{b.id}/channel_token")
    assert_equal "rotated-demo", a.reload.appsecret
    assert_not_includes a.ciphertext_for(:appsecret), "rotated-demo"
    assert_not_includes Log.pluck(:details).to_json, "demo"
    delete admins_app_path(a)
    assert_not App.exists?(a.id)
    assert Log.exists?(target_id: a.id, action: "app.destroy", actor_id: Admin.find_by(username: "boss").id)
  ensure
    ENV.delete(key)
  end
end

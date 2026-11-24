require "test_helper"
require_relative "../support/wechat_http_test"

class AppsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  setup { install_wechat_stubs }
  teardown { remove_wechat_stubs }

  test "唯一应用的 AppSecret 无法解密时仍提供独立停用入口" do
    admin = Admin.create!(username: "single_app_admin", role: "super_admin")
    sign_in admin
    app = App.create!(provider: "wechat", appid: "wxOnly", status: "active", nickname: "门诊",
      memo: "原资料", appsecret: "demo-only")
    corrupt = damage_secret(app)
    assert_equal [ app.id ], App.ids
    assert_empty AppAuthorization.where.not(refresh_token: nil)
    assert_empty Setting.where(key: Setting::SECRET_FIELDS.keys)

    get edit_admins_app_path(app)
    assert_response :unprocessable_content
    assert_select "#appsecret-error.invalid-feedback", /系统加密主密钥/
    assert_select "button", text: "停用应用"
    assert_select "#disable-app [data-admin-confirm-form='disable-app-form']", "确认停用"
    assert_select "#disable-app-form[action=?]", disable_admins_app_path(app)
    revision = css_select("#disable-app-form input[name='app[revision]']").sole["value"]

    patch disable_admins_app_path(app), params: { app: { revision: revision, appsecret: "unwanted-key", clear_secret: "1" } }
    assert_redirected_to edit_admins_app_path(app)
    patch disable_admins_app_path(app), params: { app: { revision: revision, nickname: "不应保存" } }
    assert_redirected_to edit_admins_app_path(app)
    assert_equal [ "active", "门诊", corrupt ], [ app.reload.status, app.nickname, app.appsecret_before_type_cast ]

    app.update!(memo: "并发修改")
    patch disable_admins_app_path(app), params: { app: { revision: revision } }
    assert_redirected_to edit_admins_app_path(app)
    assert_includes flash[:alert], "刷新"
    assert_equal "active", app.reload.status

    get edit_admins_app_path(app)
    revision = css_select("#disable-app-form input[name='app[revision]']").sole["value"]
    patch disable_admins_app_path(app), params: { app: { revision: revision } }
    assert_redirected_to admins_app_path(app)
    assert_equal [ "disabled", "门诊", "并发修改", corrupt ],
      [ app.reload.status, app.nickname, app.memo, app.appsecret_before_type_cast ]
    log = Log.where(action: "app.update", target_id: app.id, status: "success").sole
    assert_equal admin.id, log.actor_id
    assert_equal({ "fields" => %w[status] }, log.details)

    patch admins_app_path(app), params: { app: { revision: revision, status: "active", appsecret: "demo-replacement" } }
    assert_response :unprocessable_content
    assert_equal [ "disabled", corrupt ], [ app.reload.status, app.appsecret_before_type_cast ]
  end

  test "未配置密钥的微信应用可查看基本资料" do
    sign_in Admin.create!(username: "boss", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxDetail")
    get admins_app_path(app)
    assert_response :success
    assert_select "[role='status']", /AppSecret/
    assert_select "[data-code-src]", count: 0
  end

  test "单条 AppSecret 损坏时编辑资料和停用保留原密文" do
    sign_in Admin.create!(username: "credential_admin", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxDamaged", status: "active", appsecret: "original-demo")
    other = App.create!(provider: "wechat", appid: "wxUnaffected", status: "active", appsecret: "other-demo")
    corrupt = damage_secret(app)

    get edit_admins_app_path(app)
    assert_response :success
    assert_select "h1", "编辑应用"
    assert_select ".badge.bg-danger-lt", "解密失败"
    assert_select "#app_appsecret:not([disabled])[aria-describedby='appsecret-error']"
    assert_select "#appsecret-error.invalid-feedback", /密文已损坏/
    assert_select "#app-form [data-admin-submit]:not([disabled])"
    assert_select "#clear-app-configuration-form"
    assert_not_includes response.body, CGI.escapeHTML(corrupt)

    revision = css_select("#app_revision").sole["value"]
    patch admins_app_path(app), params: { app: { revision: revision, memo: "备注更新", status: "active", appsecret: "" } }
    assert_redirected_to admins_app_path(app)
    assert_equal [ "active", "备注更新", corrupt ], [ app.reload.status, app.memo, app.appsecret_before_type_cast ]

    get edit_admins_app_path(app)
    revision = css_select("#app_revision").sole["value"]
    patch admins_app_path(app), params: { app: { revision: revision, status: "disabled", appsecret: "" } }
    assert_redirected_to admins_app_path(app)
    assert_equal [ "disabled", corrupt ], [ app.reload.status, app.appsecret_before_type_cast ]
    assert_equal [ "active", "other-demo" ], [ other.reload.status, other.appsecret ]
    assert_equal [ %w[memo], %w[status] ], Log.where(action: "app.update", target_id: app.id).order(:id).map { |log| log.details["fields"] }
  end

  test "仅替换或清除损坏密钥，验证失败不提交且只影响目标应用" do
    sign_in Admin.create!(username: "credential_repair_admin", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxDamaged", status: "active", appsecret: "original-demo")
    other = App.create!(provider: "wechat", appid: "wxUnaffected", status: "active", appsecret: "other-demo")
    corrupt = damage_secret(app)
    calls = []
    @stubs.post("/cgi-bin/stable_token") do |env|
      body = JSON.parse(env.body)
      calls << [ body["appid"], body["secret"] ]
      calls.one? ? response_for(errcode: 40125) : response_for(access_token: "demo-stable", expires_in: 7200)
    end
    get edit_admins_app_path(app)
    revision = css_select("#app_revision").sole["value"]
    input = { revision: revision, appsecret: "new-appsecret-demo" }

    patch admins_app_path(app), params: { app: input }
    assert_response :unprocessable_content
    assert_includes response.body, "40125"
    assert_equal corrupt, app.reload.appsecret_before_type_cast
    Rails.cache.write(direct_token_key(app, "original-demo"), "old-demo-token")
    Rails.cache.write(direct_token_key(other), "other-demo-token")
    patch admins_app_path(app), params: { app: input }
    assert_redirected_to admins_app_path(app)
    assert_equal "new-appsecret-demo", app.reload.appsecret
    assert_not_includes app.ciphertext_for(:appsecret), "new-appsecret-demo"
    assert_not_equal "old-demo-token", Rails.cache.read(direct_token_key(app))
    assert_equal [ [ app.appid, "new-appsecret-demo" ] ] * 2, calls

    damage_secret(app)
    get edit_admins_app_path(app)
    clear = css_select("#clear-app-configuration-form").sole
    patch admins_app_path(app), params: { app: {
      revision: clear.at_css("input[name='app[revision]']")["value"], clear_secret: clear.at_css("input[name='app[clear_secret]']")["value"]
    } }
    assert_redirected_to edit_admins_app_path(app)
    assert_nil app.reload.appsecret
    assert_nil app.verified_digest
    assert_equal "active", app.status
    assert_equal [ "active", "other-demo" ], [ other.reload.status, other.appsecret ]
    assert_equal "other-demo-token", Rails.cache.read(direct_token_key(other))
    assert_equal 2, calls.size
    logs = Log.where(action: "app.update", target_id: app.id)
    assert_equal [ %w[appsecret], %w[appsecret] ], logs.where(status: "success").order(:id).map { |log| log.details["fields"] }
    %w[original-demo new-appsecret-demo other-demo].each { |value| assert_not_includes logs.pluck(:details).to_json, value }
  end

  test "主密钥不匹配时不能当成单条密文损坏处理" do
    sign_in Admin.create!(username: "master_key_admin", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxMismatch", status: "active", appsecret: "original-demo")
    other = App.create!(provider: "wechat", appid: "wxUnaffected", status: "active", appsecret: "other-demo")
    ciphertext = app.ciphertext_for(:appsecret)
    revision = AppConfiguration.new(app).revision
    wrong_key = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("wrong-deployment-key")

    ActiveRecord::Encryption.with_encryption_context(key_provider: wrong_key) do
      get edit_admins_app_path(app)
      assert_response :unprocessable_content
      assert_select "#appsecret-error.invalid-feedback", /系统加密主密钥/
      assert_select "#app_appsecret[disabled]"
      assert_select "#clear-app-configuration-form", count: 0
      patch admins_app_path(app), params: { app: { revision: revision, clear_secret: "1" } }
      assert_response :unprocessable_content
    end

    assert_equal ciphertext, app.reload.ciphertext_for(:appsecret)
    assert_equal [ "active", "original-demo" ], [ app.status, app.appsecret ]
    assert_equal [ "active", "other-demo" ], [ other.reload.status, other.appsecret ]
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
      patch disable_admins_app_path(app)
      assert_response :forbidden
      delete admins_app_path(app)
      assert_response :forbidden
    end
  end

  test "先按平台和类型选择账号，详情保留来源筛选，抖音仅支持小程序" do
    sign_in Admin.create!(username: "app_scope_admin", role: "super_admin")
    app = App.create!(provider: "wechat", app_type: "official_account", appid: "wxClinic", nickname: "门诊")
    App.create!(provider: "douyin", appid: "dyClinic")
    get admins_apps_path
    assert_select "tbody a", text: "门诊", count: 0
    params = { provider: "wechat", app_type: "official_account", q: "门诊" }
    get admins_apps_path(params)
    assert_select "tbody a", text: "门诊"
    get admins_app_path(app, list: params)
    assert_select "a[href=?]", admins_apps_path(params), text: /返回列表/
    assert_includes response.body, api_wechat_official_account_messages_path(appid: app.appid)
    post admins_apps_path, params: { app: { provider: "douyin", app_type: "official_account", appid: "invalid", appsecret: "new-app-fixture-only" } }
    assert_response :unprocessable_content
    assert_select "#app_type-error", text: /抖音仅支持小程序/
    assert_app_secret "未配置", "new-app-fixture-only"
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
      response_for(access_token: "demo-stable", expires_in: 7200)
    end
    change.call(status: "active", clear_secret: "1")
    assert_equal "active", app.reload.status
    assert_nil app.appsecret
    assert_equal "已验证", AppConfiguration.new(app).credential_status
    get edit_admins_app_path(app)
    assert_app_secret "已配置", "fallback-demo", "database-demo"
    ENV.delete(key)
    # With no deployment fallback, explicit clear still works for an active app.
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: "demo-stable", expires_in: 7200) }
    change.call(appsecret: "temporary-fixture-secret")
    assert_redirected_to admins_app_path(app)
    change.call(clear_secret: "1")
    assert_redirected_to edit_admins_app_path(app)
    follow_redirect!
    assert_app_secret "未配置", "temporary-fixture-secret"
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
    assert_select "dd", text: "已配置"
    assert_not_includes response.body, "demo-a"
    get edit_admins_app_path(b)
    assert_app_secret "已配置", "env-demo"
    revision = AppConfiguration.new(b).revision
    patch admins_app_path(b), params: { app: { revision: revision, status: "invalid", appsecret: "rejected-app-fixture-only" } }
    assert_response :unprocessable_content
    assert_app_secret "已配置", "env-demo", "rejected-app-fixture-only"
    assert_nil b.reload.appsecret
    patch admins_app_path(b), params: { app: { appid: "wxA", nickname: "B", revision: revision, appsecret: "" } }
    assert_redirected_to admins_app_path(b)
    assert_nil b.reload.appsecret
    assert_equal "wxB", b.appid
    revision = AppConfiguration.new(b).revision
    ENV[key] = "new-demo"
    patch admins_app_path(b), params: { app: { revision: revision, appsecret: "env-demo" } }
    assert_response :unprocessable_content
    assert_app_secret "已配置", "env-demo", "new-demo"
    assert_nil b.reload.appsecret
    [ a, b ].each { |app| Rails.cache.write(direct_token_key(app), "cached") }
    patch admins_app_path(a), params: { app: { revision: AppConfiguration.new(a).revision, appsecret: "rotated-demo" } }
    assert_nil Rails.cache.read(direct_token_key(a.reload))
    assert_equal "cached", Rails.cache.read(direct_token_key(b))
    assert_equal "rotated-demo", a.reload.appsecret
    assert_not_includes a.ciphertext_for(:appsecret), "rotated-demo"
    assert_not_includes Log.pluck(:details).to_json, "demo"
    delete admins_app_path(a)
    assert_not App.exists?(a.id)
    assert Log.exists?(target_id: a.id, action: "app.destroy", actor_id: Admin.find_by(username: "boss").id)
  ensure
    ENV.delete(key)
  end

  test "首次启用的凭据验证令牌供其他功能共用" do
    sign_in Admin.create!(username: "direct_verify", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wxEnable", status: "disabled")
    issued = 0
    @stubs.post("/cgi-bin/stable_token") do
      issued += 1
      response_for(access_token: "first-stable", expires_in: 7200)
    end
    patch admins_app_path(app), params: {app: {revision: AppConfiguration.new(app).revision, status: "active", appsecret: "demo-hospital"}}
    assert_redirected_to admins_app_path(app)
    assert_equal "first-stable", Wechat::AccessToken.new(app.reload).fetch
    assert_equal 1, issued
  end

  test "空授权草稿随空应用清除，已发生的授权与操作历史保留" do
    sign_in Admin.create!(username: "direct_history", role: "super_admin")
    empty, used = %w[wxEmpty wxUsed].map { |id| App.create!(provider: "wechat", appid: id) }
    empty.create_app_authorization!
    used.create_app_authorization!(revoked_at: 1.day.ago)
    assert_difference("App.count", -1) { delete admins_app_path(empty) }
    assert_no_difference("App.count") { delete admins_app_path(used) }
    assert_match(/已有微信授权记录/, flash[:alert])
  end

  test "有真实用户或公众号通知配置时保留记录并分别提示原因" do
    sign_in Admin.create!(username: "deletion_admin", role: "super_admin")
    mini = App.create!(provider: "wechat", appid: "wxUsedMini")
    user_app = UserApp.create!(app: mini, user: User.create!(platform: "wechat"), openid: "local-deletion-fan")
    account = App.create!(provider: "wechat", app_type: "official_account", appid: "wxConfiguredOA")
    Setting.create!(key: "notification", settings: { accounts: { account.appid => { "keywords" => [] } } })
    delete admins_app_path(mini)
    assert_includes flash[:alert], "已有用户身份记录"
    assert UserApp.exists?(user_app.id)
    delete admins_app_path(account)
    assert_includes flash[:alert], "已有公众号通知配置"
    assert App.exists?(account.id)
    log = Log.find_by!(action: "app.destroy", target_id: account.id, status: "failed")
    get admins_operation_log_path(log)
    assert_select "dd", text: "已有公众号通知配置，只能停用"
  end

  private

  def assert_app_secret(status, *secrets)
    assert_select "#app_appsecret[type=text][data-write-only][autocomplete=off]:not([value])"
    assert_select "label[for=app_appsecret] ~ [data-credential-status]", text: status
    secrets.each { |secret| assert_not_includes response.body, secret }
  end

  def damage_secret(app)
    envelope = JSON.parse(app.reload.ciphertext_for(:appsecret))
    payload = Base64.strict_decode64(envelope.fetch("p"))
    payload.setbyte(0, payload.getbyte(0) ^ 1)
    envelope["p"] = Base64.strict_encode64(payload)
    corrupt = envelope.to_json
    App.where(id: app.id).update_all([ "appsecret = ?", corrupt ])
    corrupt
  end
end

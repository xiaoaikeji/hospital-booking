require "test_helper"
require_relative "../support/wechat_http_test"

class WechatQrcodesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  PNG = "\x89PNG\r\n\x1a\n".b

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "qr_admin", role: "super_admin")
    sign_in @admin
    @direct = App.create!(provider: "wechat", appid: "wxDirect", appsecret: "demo-direct-secret")
    @managed = App.create!(provider: "wechat", appid: "wxManaged", appsecret: "demo-unused")
    auth = @managed.create_app_authorization!(refresh_token: "demo-refresh")
    Rails.cache.write("apps/#{@managed.id}/channel_token", { value: "managed", revision: auth.updated_at.to_f })
  end
  teardown { remove_wechat_stubs }

  test "列表按平台提供正式版码与微信授权，打开前不调用微信" do
    douyin = App.create!(provider: "douyin", appid: "dyA")
    get admins_apps_path
    assert_response :success
    [ @direct, @managed ].each do |app|
      assert_select "button[data-qrcode-url=?]", admins_app_qrcode_path(app), text: "二维码"
    end
    assert_select "button[data-qrcode-url=?]", admins_app_qrcode_path(douyin), count: 0
    assert_select "form[action=?]", admins_app_authorization_path(@direct), count: 1
    assert_select "form[action=?]", admins_app_authorization_path(@managed), count: 0
    get admins_app_qrcode_path(douyin)
    assert_response :not_found
  end

  test "公众号关注码只从微信图片域或账号原始 ID 读取，取消授权后不能复用缓存" do
    @managed = App.create!(provider: "wechat", app_type: "official_account", appid: "wxOfficial")
    @managed.create_app_authorization!(refresh_token: "demo-refresh")
    Rails.cache.write("wechat/component/wxPlatform/token", "demo-platform")
    @stubs.post("/cgi-bin/component/api_get_authorizer_info") do |env|
      assert_equal @managed.appid, JSON.parse(env.body).fetch("authorizer_appid")
      response_for(authorizer_info: { qrcode_url: "https://example.org/bad", user_name: "gh_managed" })
    end
    @stubs.get("https://open.weixin.qq.com/qr/code?username=gh_managed") do
      [200, { "Content-Type" => "image/png" }, PNG + "official"]
    end
    get admins_app_qrcode_path(@managed)
    assert_response :success
    assert_equal PNG + "official", response.body.b
    @managed.app_authorization.update!(refresh_token: nil)
    get admins_app_qrcode_path(@managed)
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "公众号的平台授权"
  end

  test "直连与代管各取本应用的正式版码，图片缓存按应用区分" do
    @stubs.post("/cgi-bin/stable_token") do |env|
      assert_equal({ "grant_type" => "client_credential", "appid" => @direct.appid, "secret" => "demo-direct-secret" }, JSON.parse(env.body))
      response_for(access_token: "direct")
    end
    requests = []
    @stubs.post("/wxa/getwxacodeunlimit") do |env|
      token = env.params.fetch("access_token")
      requests << token
      assert_equal({ "scene" => "home", "env_version" => "release", "check_path" => true, "width" => 430 }, JSON.parse(env.body))
      [ 200, { "Content-Type" => "image/png" }, PNG + token ]
    end
    [ [ @direct, "direct" ], [ @managed, "managed" ], [ @direct, "direct" ] ].each do |app, token|
      get admins_app_qrcode_path(app)
      assert_response :success
      assert_equal "image/png", response.media_type
      assert_equal PNG + token, response.body.b
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
    end
    assert_equal %w[direct managed], requests
  end

  test "基本资料原位刷新两种码，仅清空本应用缓存并记录一次人工操作" do
    trial = @managed.mini_program_releases.create!(current_build: true, status: "uploaded", template_id: "7", version: "2.0", description: "体验版", operator: @admin)
    other_key = WechatPlatform::ReleaseQrcode.release_key(@direct)
    Rails.cache.write(other_key, PNG + "B")
    calls = Hash.new(0)
    @stubs.post("/wxa/getwxacodeunlimit") { [200, { "Content-Type" => "image/png" }, PNG + "release#{calls[:release] += 1}"] }
    @stubs.get("/wxa/get_qrcode") { [200, { "Content-Type" => "image/png" }, PNG + "trial#{calls[:trial] += 1}"] }
    release_url = admins_app_qrcode_path(@managed)
    trial_url = trial_admins_app_release_path(@managed, trial)
    get admins_app_path(@managed)
    assert_select "[data-qrcode-panel] [data-code-src=?]", release_url
    assert_select "[data-qrcode-panel] [data-code-src=?]", trial_url
    assert_empty calls
    2.times do
      get release_url
      assert_equal PNG + "release1", response.body.b
      get trial_url
      assert_equal PNG + "trial1", response.body.b
    end
    post refresh_admins_app_qrcode_path(@managed), xhr: true
    assert_response :success
    assert_select "[data-qrcode-panel] [data-code-src=?]", trial_url
    assert_equal PNG + "B", Rails.cache.read(other_key)
    get release_url
    assert_equal PNG + "release2", response.body.b
    get trial_url
    assert_equal PNG + "trial2", response.body.b
    log = Log.where(action: "wechat.qrcode_refresh").sole
    assert_equal [@managed.id, @admin.id, "success"], [log.target_id, log.actor_id, log.status]

    trial.update!(current_build: false)
    post refresh_admins_app_qrcode_path(@managed), xhr: true
    assert_select "[data-qrcode-panel] [data-code-src=?]", trial_url, count: 0
    assert_includes response.body, "暂无可用的体验版"
    get trial_url
    assert_response :service_unavailable
    assert_equal({ release: 2, trial: 2 }, calls)
  end

  test "正式版命中缓存后体验码令牌过期，单独重试取得新图并缓存" do
    release = @managed.mini_program_releases.create!(current_build: true, status: "uploaded",
      template_id: "8", version: "2.1", description: "门诊体验版", operator: @admin)
    Rails.cache.write(WechatPlatform::ReleaseQrcode.release_key(@managed), PNG + "online")
    Rails.cache.write("wechat/component/wxPlatform/token", "component")
    requests = []
    @stubs.post("/cgi-bin/component/api_authorizer_token") do |env|
      requests << ["renew", JSON.parse(env.body).fetch("authorizer_appid")]
      response_for(authorizer_access_token: "renewed", expires_in: 7200)
    end
    @stubs.get("/wxa/get_qrcode") do |env|
      token = env.params.fetch("access_token")
      requests << ["trial", token]
      token == "managed" ? response_for(errcode: 42001) : [200, { "Content-Type" => "image/png" }, PNG + "trial"]
    end
    get admins_app_qrcode_path(@managed)
    assert_equal PNG + "online", response.body.b
    url = trial_admins_app_release_path(@managed, release)
    get url
    assert_response :service_unavailable
    assert_includes response.parsed_body.fetch("error"), "42001"
    assert_equal [["trial", "managed"]], requests
    get url
    assert_equal [["trial", "managed"], ["renew", @managed.appid], ["trial", "renewed"]], requests
    assert_response :success
    assert_equal PNG + "trial", response.body.b
    get url
    assert_equal "image/png", response.media_type
    assert_equal 3, requests.size
  end

  test "微信拒绝旧授权令牌时仅清除此应用的失效缓存" do
    key = "apps/#{@managed.id}/channel_token"
    @stubs.post("/wxa/getwxacodeunlimit") { response_for(errcode: 40001) }
    get admins_app_qrcode_path(@managed)
    assert_response :unprocessable_content
    assert_nil Rails.cache.read(key)
  end

  test "无凭据或微信拒绝签发时显示原因，运营和客服不得直接获取图片" do
    @direct.update!(appsecret: nil)
    get admins_app_qrcode_path(@direct)
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "本应用的 AppSecret"
    @stubs.post("/wxa/getwxacodeunlimit") { response_for(errcode: 41030) }
    get admins_app_qrcode_path(@managed)
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "正式版"
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: role, role: role)
      get admins_app_qrcode_path(@managed)
      assert_response :forbidden
      assert_no_difference("Log.where(action: 'wechat.qrcode_refresh').count") do
        post refresh_admins_app_qrcode_path(@managed)
        assert_response :forbidden
      end
    end
  end
end

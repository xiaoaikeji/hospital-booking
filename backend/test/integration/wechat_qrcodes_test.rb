require "test_helper"
require_relative "../support/wechat_http_test"

class WechatQrcodesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  PNG = "\x89PNG\r\n\x1a\n".b

  setup do
    install_wechat_stubs
    sign_in Admin.create!(username: "qr_admin", role: "super_admin")
    @a, @b = %w[wxClinicA wxClinicB].map { |id| App.create!(provider: "wechat", appid: id, status: "active", appsecret: "demo-#{id}") }
    @tokens = []
    @images = []
    @stubs.post("/cgi-bin/stable_token") do |env|
      body = JSON.parse(env.body)
      @tokens << body
      response_for(access_token: "#{body.fetch('appid')}-#{@tokens.size}", expires_in: 7200)
    end
    @stubs.post("/wxa/getwxacodeunlimit") do |env|
      body = JSON.parse(env.body)
      assert_equal "home", body["scene"]
      assert_equal body["env_version"] == "release", body["check_path"]
      @images << [env.params.fetch("access_token"), body.fetch("env_version")]
      @reject ? response_for(errcode: @reject) : [200, {"Content-Type" => "image/png"}, PNG + @images.last.join("/")]
    end
  end
  teardown { remove_wechat_stubs }

  def scan(app, version = "release")
    get admins_app_qrcode_path(app, version: version)
    assert_response :success
    assert_equal "image/png", response.media_type
    response.body
  end

  test "正式版与已有体验版复用账号令牌，按账号和版本缓存，刷新只影响当前账号" do
    get admins_apps_path
    assert_select "[data-qrcode-url]", count: 2
    assert_empty @tokens
    [@a, @b].each do |app|
      get admins_app_path(app)
      assert_select "[data-code-src]", count: 2
      %w[release trial].each { |version| assert_equal scan(app, version), scan(app, version) }
    end
    assert_equal 2, @tokens.size
    assert_equal 4, @images.size
    assert_difference("Log.where(action: 'wechat.qrcode_refresh').count", 1) do
      post refresh_admins_app_qrcode_path(@a), xhr: true
      assert_response :success
    end
    [@b, @a].each { |app| scan(app) }
    assert_equal 5, @images.size
    assert_equal @a.appid + "-1", @images.last.first
  end

  test "令牌失效与密钥轮换只影响 A，迟到的失效回执不能驱逐新令牌" do
    scan(@a)
    scan(@b)
    old = Wechat::AccessToken.new(@a)
    rejected_token = old.fetch
    @reject = 42001
    get admins_app_qrcode_path(@a, version: "trial")
    assert_response :unprocessable_content
    assert_nil Rails.cache.read(direct_token_key(@a))
    @reject = nil
    scan(@b, "trial")
    scan(@a, "trial")
    assert_equal [@a.appid, @b.appid, @a.appid], @tokens.pluck("appid")
    assert_equal true, @tokens.last.fetch("force_refresh")
    old.expire(rejected_token)
    assert_equal "#{@a.appid}-3", Wechat::AccessToken.new(@a).fetch
    @a.update!(appsecret: "demo-new-for-A")
    scan(@a)
    assert_equal "demo-new-for-A", @tokens.last.fetch("secret")
    scan(@b)
    assert_equal 1, @tokens.count { |request| request["appid"] == @b.appid }
  end

  test "缺少凭据、微信拒绝页面和无权限的直接请求" do
    @a.update!(appsecret: nil)
    get admins_app_qrcode_path(@a)
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "AppSecret"
    @reject = 41030
    get admins_app_qrcode_path(@b, version: "trial")
    assert_response :unprocessable_content
    assert_includes response.parsed_body.fetch("error"), "体验版"
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: role, role: role)
      get admins_app_qrcode_path(@b)
      assert_response :forbidden
      post refresh_admins_app_qrcode_path(@b)
      assert_response :forbidden
    end
  end
end

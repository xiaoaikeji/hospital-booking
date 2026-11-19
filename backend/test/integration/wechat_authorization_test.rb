require "test_helper"
require_relative "../support/wechat_http_test"

class WechatAuthorizationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "auth_admin", role: "super_admin")
    @target = App.create!(provider: "wechat", appid: "wxA")
    sign_in @admin
  end
  teardown { remove_wechat_stubs }

  def authorize(returned_id)
    @stubs.post("/cgi-bin/component/api_component_token") do |env|
      assert_equal "demo-ticket", JSON.parse(env.body)["component_verify_ticket"]
      response_for(component_access_token: "demo-platform-token", expires_in: 7200)
    end
    @stubs.post("/cgi-bin/component/api_create_preauthcode") { response_for(pre_auth_code: "demo-preauth") }
    post admins_app_authorization_path(@target)
    assert_response :redirect
    query = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal @target.appid, query["biz_appid"]
    @stubs.post("/cgi-bin/component/api_query_auth") do
      response_for(authorization_info: { authorizer_appid: returned_id, authorizer_refresh_token: "demo-refresh",
        func_info: [ { funcscope_category: { id: 17 } } ] })
    end
    @stubs.post("/cgi-bin/component/api_get_authorizer_info") { response_for(authorizer_info: { user_name: "gh_A" }) }
    get query.fetch("redirect_uri") + "&auth_code=demo-auth-code"
  end

  test "票据验签、授权回跳归属、刷新轮换、取消授权和历史保护" do
    path = "/api/wechat/component/events"
    ticket = "<xml><AppId>wxPlatform</AppId><InfoType>component_verify_ticket</InfoType><ComponentVerifyTicket>demo-ticket</ComponentVerifyTicket></xml>"
    signed_push(path, ticket, tamper: true)
    assert_response :forbidden
    signed_push(path, ticket)
    assert_response :success
    authorize("wxB")
    assert_not @target.reload.app_authorization.authorized?
    authorize("wxA")
    auth = @target.reload.app_authorization
    assert auth.authorized?
    assert_not_includes auth.ciphertext_for(:refresh_token), "demo-refresh"
    assert_equal [ 17 ], auth.scopes
    @stubs.post("/cgi-bin/component/api_authorizer_token") do |env|
      assert_equal "demo-refresh", JSON.parse(env.body)["authorizer_refresh_token"]
      response_for(authorizer_access_token: "demo-access", authorizer_refresh_token: "demo-rotated", expires_in: 7200)
    end
    assert_equal "demo-access", WechatPlatform::AuthorizerToken.fetch(@target)
    assert_equal "demo-rotated", auth.reload.refresh_token
    delete admins_app_path(@target)
    assert App.exists?(@target.id)
    signed_push(path, "<xml><AppId>wxPlatform</AppId><InfoType>unauthorized</InfoType><CreateTime>#{Time.current.to_i}</CreateTime><AuthorizerAppid>wxA</AuthorizerAppid></xml>")
    assert_response :success
    assert_raises(WechatPlatform::Error) { WechatPlatform::AuthorizerToken.fetch(@target) }
    assert_not_includes Log.pluck(:details).to_json, "demo-"
  end

  test "平台状态按本院应用统计，验签后才显示票据接收时间，刷新不换令牌" do
    platform = WechatPlatform::ComponentToken.new
    @target.create_app_authorization!(refresh_token: "local-authorizer")
    official = App.create!(provider: "wechat", app_type: "official_account", appid: "wxService")
    official.create_app_authorization!(revoked_at: Time.current)
    idle = App.create!(provider: "wechat", appid: "wxPending")
    idle.create_app_authorization!(state_digest: "pending")
    push_url = api_wechat_component_events_path
    ticket = "<xml><AppId>wxPlatform</AppId><InfoType>component_verify_ticket</InfoType><ComponentVerifyTicket>local-ticket</ComponentVerifyTicket></xml>"

    signed_push(push_url, ticket, tamper: true)
    assert_response :forbidden
    assert_nil platform.ticket_received_at
    Rails.cache.write(platform.ticket_key, "legacy-ticket", expires_in: 12.hours)
    get admins_wechat_platform_path
    assert_response :success
    assert_includes response.body, "等待下次推送更新时间"
    assert_includes response.body, "/api/wechat/component/apps/$APPID$/messages"
    assert_select "dt", text: "微信小程序" do |labels|
      assert_equal "已授权 1 个，已取消 0 个", labels.first.next_element.text
    end
    assert_select "dt", text: "微信公众号" do |labels|
      assert_equal "已授权 0 个，已取消 1 个", labels.first.next_element.text
    end

    freeze_time do
      signed_push(push_url, ticket)
      assert_response :success
      assert_equal Time.current, platform.ticket_received_at
      Rails.cache.write(platform.token_key, "local-platform-token", expires_in: 1.hour)
      assert_no_difference("Log.count") { get admins_wechat_platform_path }
      assert_select "dd", text: Time.current.strftime("%Y-%m-%d %H:%M")
      assert_select "dd", text: "已缓存"
      (@component.except(:appid).values + %w[local-ticket local-platform-token local-authorizer legacy-ticket]).each do |secret|
        assert_not_includes response.body, secret
      end
      travel 13.hours
      get admins_wechat_platform_path
      assert_select "dd", text: "暂无有效票据"
      assert_select "dd", text: "暂无缓存"
    end
  end

  test "平台未配置仍显示接收地址，运营和客服看不到诊断入口也不能直访" do
    ENV.delete("WECHAT_COMPONENT_APPSECRET")
    get admins_wechat_platform_path
    assert_response :success
    assert_select "[role=status]", text: /WECHAT_COMPONENT_APPSECRET/
    assert_includes response.body, api_wechat_component_events_url
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "platform_#{role}", role: role)
      get admins_root_path
      assert_select "a[href=?]", admins_wechat_platform_path, count: 0
      get admins_wechat_platform_path
      assert_response :forbidden
    end
  end

  test "更新授权和乱序通知保留初始授权时间，取消后仍能查阅" do
    Rails.cache.write("wechat/component/wxPlatform/token", "test-token")
    authorize("wxA")
    auth = @target.reload.app_authorization
    original = auth.authorized_at
    assert original
    @stubs.post("/cgi-bin/component/api_query_auth") do
      response_for(authorization_info: { authorizer_appid: "wxA", authorizer_refresh_token: "demo-new",
        func_info: [{ funcscope_category: { id: 18 } }] })
    end
    push = lambda do |kind, at|
      signed_push("/api/wechat/component/events", "<xml><AppId>wxPlatform</AppId><InfoType>#{kind}</InfoType><CreateTime>#{at}</CreateTime><AuthorizerAppid>wxA</AuthorizerAppid><AuthorizationCode>demo-code</AuthorizationCode></xml>")
      assert_response :success
    end
    push.call("updateauthorized", original.to_i + 5)
    assert_equal [18], auth.reload.scopes
    push.call("unauthorized", original.to_i + 1)
    assert auth.reload.authorized?
    assert_nil auth.revoked_at
    push.call("unauthorized", original.to_i + 7)
    assert_not auth.reload.authorized?
    assert_equal original, auth.authorized_at
    assert_equal original.to_i + 7, auth.revoked_at.to_i
    get admins_app_path(@target)
    assert_select "dt", text: "授权时间"
    assert_select "dt", text: "取消时间"
  end

  test "同一超管的两个授权标签页各自回跳且只能消费一次" do
    b = App.create!(provider: "wechat", appid: "wxB")
    Rails.cache.write("wechat/component/wxPlatform/token", "demo-platform-token")
    @stubs.post("/cgi-bin/component/api_create_preauthcode") { response_for(pre_auth_code: "demo-preauth") }
    callbacks = [ @target, b ].map do |app|
      post admins_app_authorization_path(app)
      query = Rack::Utils.parse_query(URI(response.location).query)
      query.fetch("redirect_uri") + "&auth_code=#{app.appid}"
    end
    exchanges = []
    @stubs.post("/cgi-bin/component/api_query_auth") do |env|
      appid = JSON.parse(env.body).fetch("authorization_code")
      exchanges << appid
      response_for(authorization_info: { authorizer_appid: appid, authorizer_refresh_token: "refresh-#{appid}" })
    end
    @stubs.post("/cgi-bin/component/api_get_authorizer_info") { response_for(authorizer_info: { user_name: "gh_demo" }) }

    # 即使是同一超管，拿到链接的另一个浏览器也不能消费原会话的 state。
    foreign_browser = open_session
    sign_in @admin
    foreign_browser.get callbacks.first
    assert_equal admins_apps_url, foreign_browser.response.location
    travel 11.minutes do
      get callbacks.first
      assert_redirected_to admins_apps_path
    end
    [ @target, b ].zip(callbacks) do |app, callback|
      get callback
      assert_redirected_to admins_app_path(app)
      assert_equal "refresh-#{app.appid}", app.reload.app_authorization.refresh_token
      get callback
      assert_redirected_to admins_apps_path
    end
    assert_equal %w[wxA wxB], exchanges
  end

  test "运营和客服直接请求授权回跳、上传和每个审核动作均返回 403" do
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: role, role: role)
      { post: [ admins_app_authorization_path(@target), admins_app_releases_path(@target), submit_admins_app_release_path(@target, 1),
                resolve_admins_app_audit_path(@target, 1), withdraw_admins_app_audit_path(@target, 1), publish_admins_app_audit_path(@target, 1) ],
        get: [ api_wechat_authorization_callback_path, new_admins_app_release_path(@target), trial_admins_app_release_path(@target, 1) ],
        patch: [ verify_upload_admins_app_release_path(@target, 1), close_admins_app_release_path(@target, 1), sync_admins_app_audit_path(@target, 1) ],
        delete: [ admins_app_release_path(@target, 1) ] }.each do |method, urls|
        urls.each do |url|
          public_send(method, url)
          assert_response :forbidden
        end
      end
    end
  end
end

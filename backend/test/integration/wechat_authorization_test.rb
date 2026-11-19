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

require "test_helper"
require_relative "../support/wechat_http_test"

class WechatExperiencersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "tester_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[A B].map do |key|
      app = App.create!(provider: "wechat", appid: "wxTester#{key}")
      auth = app.create_app_authorization!(refresh_token: "test-only")
      Rails.cache.write("apps/#{app.id}/channel_token", { value: key, revision: auth.updated_at.to_f })
      app
    end
    @lists = { "A" => [], "B" => [ "opaque-b" ] }
    @writes = []
    @stubs.post("/wxa/memberauth") do |env|
      next response_for(errcode: @read_error) if @read_error
      assert_equal({ "action" => "get_experiencer" }, JSON.parse(env.body))
      response_for(members: @lists.fetch(env.params.fetch("access_token")).map { |id| { userstr: id } })
    end
    @stubs.post("/wxa/bind_tester") do |env|
      @writes << [env.params.fetch("access_token"), JSON.parse(env.body)]
      next response_for({}) if @unknown_result
      next response_for(errcode: 85001) if JSON.parse(env.body)["wechatid"] == "missing"
      @lists.fetch(env.params.fetch("access_token")) << "opaque-a"
      response_for(userstr: "opaque-a")
    end
    @stubs.post("/wxa/unbind_tester") do |env|
      @writes << [env.params.fetch("access_token"), JSON.parse(env.body)]
      @lists.fetch(env.params.fetch("access_token")).delete(JSON.parse(env.body)["userstr"])
      response_for(errcode: 0)
    end
  end
  teardown { remove_wechat_stubs }

  test "bind and unbind use the selected app, confirm membership, redact identifiers and return to filtered tab" do
    context = { list: { q: "hospital" } }
    tab = admins_app_path(@a, **context, tab: "experiencers")
    get tab
    assert_response :success
    assert_select "h2", text: "暂无体验者"
    post admins_app_experiencers_path(@a, context), params: { wechatid: " tester-one " }
    assert_redirected_to tab
    follow_redirect!
    assert_select "button", text: "解绑"
    assert_select "td", text: "opaque-a"
    delete admins_app_experiencers_path(@a), params: { userstr: "opaque-b" }
    assert_match(/已不在本应用/, flash[:alert])
    delete admins_app_experiencers_path(@a, context), params: { userstr: "opaque-a" }
    assert_redirected_to tab
    assert_equal [ ["A", { "wechatid" => "tester-one" }], ["A", { "userstr" => "opaque-a" }] ], @writes
    assert_equal ["opaque-b"], @lists["B"]
    logs = Log.where(target_type: "App", target_id: @a.id, actor_type: "Admin", actor_id: @admin.id).order(:id)
    assert_equal %w[success failed success], logs.pluck(:status)
    assert_no_match(/tester-one|opaque-/, logs.pluck(:details).to_s)
  end

  test "rejected and invalid binding retain the tab, invalidated authorization removes writes" do
    post admins_app_experiencers_path(@a), params: { wechatid: "missing" }
    assert_match(/微信号不存在/, flash[:alert])
    post admins_app_experiencers_path(@a), params: { wechatid: "  " }
    assert_match(/请填写/, flash[:alert])
    @a.app_authorization.update!(revoked_at: Time.current, refresh_token: nil)
    get admins_app_path(@a, tab: "experiencers")
    assert_select "a", text: "查看平台授权"
    assert_select "input[name=wechatid]", count: 0
    post admins_app_experiencers_path(@a), params: { wechatid: "retry" }
    assert_match(/平台授权/, flash[:alert])
    assert_equal 1, @writes.size
  end

  test "unavailable permission hides controls and responses without a write result request verification" do
    @read_error = 61007
    get admins_app_path(@a, tab: "experiencers")
    assert_response :success
    assert_select "a", text: "重新读取"
    assert_select "[role=alert]", text: /更新平台授权/
    assert_select "input[name=wechatid]", count: 0
    @read_error = nil
    @unknown_result = true
    post admins_app_experiencers_path(@a), params: { wechatid: "unconfirmed" }
    assert_match(/未确认绑定结果/, flash[:alert])
    assert_equal 1, @writes.size
    assert_equal "failed", Log.where(action: "wechat.tester_bind", target_id: @a.id).sole.status
  end

  test "official accounts and non-admin roles cannot manage experience access" do
    official = App.create!(provider: "wechat", app_type: "official_account", appid: "wxTesterOfficial")
    get admins_app_path(official)
    assert_select "a.nav-link", text: "体验者", count: 0
    post admins_app_experiencers_path(official), params: { wechatid: "attempt" }
    assert_response :not_found
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "tester_#{role}", role: role)
      get admins_app_path(@b, tab: "experiencers")
      assert_response :forbidden
      post admins_app_experiencers_path(@b), params: { wechatid: "attempt" }
      assert_response :forbidden
      delete admins_app_experiencers_path(@b), params: { userstr: "opaque-b" }
      assert_response :forbidden
    end
    assert_empty @writes
  end
end

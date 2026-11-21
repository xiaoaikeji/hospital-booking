require "test_helper"
require_relative "../support/wechat_http_test"

class WechatPluginsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "plugin_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxPluginA wxPluginB].map do |id|
      app = App.create!(provider: "wechat", appid: id)
      configure_account(app)
      app
    end
    @rows = { @a.appid => [], @b.appid => [{ "appid" => "wxOther", "nickname" => "B 的插件", "status" => 2 }] }
    @writes = []
    @stubs.post("/wxa/plugin") do |env|
      rows = @rows.fetch(env.params.fetch("access_token"))
      body = JSON.parse(env.body)
      if body["action"] == "list"
        @read_error ? response_for(@read_error) : response_for(plugin_list: rows)
      else
        @writes << [env.params.fetch("access_token"), body]
        if @reject_write
          response_for(errcode: 89200)
        else
          case body.fetch("action")
          when "apply"  then rows << { "appid" => body.fetch("plugin_appid"), "status" => 1 }
          when "update"
            rows.find { |r| r["appid"] == body["plugin_appid"] }["version"] = body.fetch("user_version") unless @omit_version
          when "unbind" then rows.reject! { |r| r["appid"] == body["plugin_appid"] }
          end
          raise Faraday::TimeoutError if @write_timeout
          response_for(errcode: 0)
        end
      end
    end
  end
  teardown { remove_wechat_stubs }

  test "插件申请按应用分开，拒绝时回原页保留输入，写超时不自动重发" do
    get admins_plugins_path
    assert_select ".empty-title", "请选择小程序"
    get admins_plugins_path(app_id: @b.id)
    assert_select "table", text: /B 的插件/
    assert_select "table form", count: 0
    assert_no_difference("Log.count") { get admins_app_path(@a, tab: "plugins") }
    assert_select ".empty-title", "暂无插件"
    @reject_write = true
    post admins_app_plugins_path(@a), params: {plugin_appid: "wxTool"}
    assert_redirected_to admins_app_path(@a, tab: "plugins")
    follow_redirect!
    assert_select "[role=alert]", text: /89200/
    assert_select "input[name=plugin_appid][value=wxTool]"
    @reject_write = false
    @write_timeout = true
    post admins_app_plugins_path(@a), params: {plugin_appid: "wxTool"}
    assert_match(/核实当前插件状态/, flash[:alert])
    follow_redirect!
    assert_select "table", text: /申请中/
    post admins_app_plugins_path(@a), params: {plugin_appid: "wxTool"}
    assert_equal 2, @writes.size
    assert_equal [@a.appid], @writes.map(&:first).uniq
    assert_equal ["wxOther"], @rows[@b.appid].pluck("appid")
  end

  test "更新和解除按当前应用重新读名单，微信成功才记录成功审计" do
    post admins_app_plugins_path(@a), params: {plugin_appid: "wxTool"}
    patch admins_app_plugin_path(@b, "wxTool"), params: {user_version: "1.2"}
    delete admins_app_plugin_path(@b, "wxTool")
    assert_equal 1, @writes.size
    @rows.fetch(@a.appid).first["status"] = 2
    @reject_write = true
    patch admins_app_plugin_path(@a, "wxTool"), params: {user_version: "1.2"}
    follow_redirect!
    assert_select "input[name=user_version][value='1.2']"
    @reject_write = false
    patch admins_app_plugin_path(@a, "wxTool"), params: {user_version: "1.2"}
    assert_redirected_to admins_app_path(@a, tab: "plugins")
    patch admins_app_plugin_path(@a, "wxTool"), params: {user_version: "1.2"}
    delete admins_app_plugin_path(@a, "wxTool")
    assert_redirected_to admins_app_path(@a, tab: "plugins")
    delete admins_app_plugin_path(@a, "wxTool")
    assert_equal %w[apply update update unbind], @writes.map { |_, body| body.fetch("action") }
    assert_equal({ "action" => "update", "plugin_appid" => "wxTool", "user_version" => "1.2" }, @writes[2].last)
    assert_empty @rows.fetch(@a.appid)
    assert_equal %w[wechat.plugin_apply wechat.plugin_update wechat.plugin_unbind],
      Log.where(actor_type: "Admin", actor_id: @admin.id, target_type: "App", target_id: @a.id, status: "success").order(:id).pluck(:action)
  end

  test "申请中、已拒绝、已超时和未知状态不显示更新且阻止直接提交" do
    [1, 3, 4, nil].each do |status|
      @rows[@a.appid] = [{ "appid" => "wxTool", "status" => status }]
      get admins_app_path(@a, tab: "plugins")
      assert_select "input[name=user_version]", count: 0
      patch admins_app_plugin_path(@a, "wxTool"), params: { user_version: "1.2" }
      assert_match(/仅申请通过/, flash[:alert])
    end
    assert_empty @writes
  end

  test "插件名单无版本时超时阻止重复更新，按应用核实实际版本，成功后也不会重发" do
    @omit_version = @write_timeout = true
    [@a, @b].each { |app| @rows[app.appid] = [{ "appid" => "wxTool", "status" => 2 }] }
    update = ->(app, version) { patch admins_app_plugin_path(app, "wxTool"), params: { user_version: version } }
    verify = ->(app, op, value) { post verify_admins_app_plugin_path(app, "wxTool"), params: { operation_id: op.id, confirmed: "1", actual_version: value } }
    2.times { update.call(@a, "1.2") }
    assert_equal 1, @writes.size
    op = WechatPluginUpdate.find_by!(app: @a, plugin_appid: "wxTool")
    get admins_app_path(@a, tab: "plugins")
    assert_select "input[name=user_version]", count: 0
    assert_select "input[name=operation_id][value=?]", op.id
    verify.call(@b, op, "1.2")
    assert_not op.reload.confirmed?
    saved = @rows.fetch(@a.appid).pop
    get admins_app_path(@a, tab: "plugins")
    @rows.fetch(@a.appid) << saved
    update.call(@a, "1.2")
    assert_equal 1, @writes.size
    verify.call(@a, op, "1.2")
    assert op.reload.confirmed?
    update.call(@a, "1.2")
    assert_equal 1, @writes.size
    update.call(@a, "1.3")
    newest = WechatPluginUpdate.find_by!(app: @a)
    verify.call(@a, op, "1.2")
    assert_not newest.reload.confirmed?
    verify.call(@a, newest, "1.2")
    @write_timeout = false
    2.times { update.call(@a, "1.3") }
    update.call(@b, "1.2")
    assert_equal [@a.appid, @a.appid, @a.appid, @b.appid], @writes.map(&:first)
    delete admins_app_plugin_path(@a, "wxTool")
    assert_not WechatPluginUpdate.exists?(app: @a)
    assert WechatPluginUpdate.exists?(app: @b, version: "1.2")
  end

  test "已确认更新后旧名单不回写或重发，名单追上或人工核实后才恢复" do
    @omit_version = true
    plugin = { "appid" => "wxTool", "status" => 2, "version" => "1.0" }
    @rows[@a.appid] = [plugin]
    url = admins_app_plugin_path(@a, "wxTool")
    patch url, params: {user_version: "2.0"}
    op = WechatPluginUpdate.find_by!(app: @a, plugin_appid: "wxTool")
    get admins_app_path(@a, tab: "plugins")
    assert_select "input[name=operation_id][value=?]", op.id
    patch url, params: {user_version: "2.0"}
    assert_equal "2.0", op.reload.version
    assert_equal 1, @writes.size
    plugin["version"] = "2.0"
    get admins_app_path(@a, tab: "plugins")
    assert_select "input[name=user_version]"
    patch url, params: {user_version: "2.0"}
    assert_equal 1, @writes.size
    plugin["version"] = "3.0"
    args = {operation_id: op.id, confirmed: "1"}
    post verify_admins_app_plugin_path(@a, "wxTool"), params: args.merge(actual_version: "1.0")
    assert_equal "2.0", op.reload.version
    post verify_admins_app_plugin_path(@a, "wxTool"), params: args.merge(actual_version: "3.0")
    assert_equal "3.0", op.reload.version
    patch url, params: {user_version: "2.0"}
    assert_equal 2, @writes.size
  end

  test "读取失效令牌或残缺名单后收起写入口，非超管和未配置的小程序不能管理" do
    @read_error = {errcode: 42001}
    get admins_app_path(@a, tab: "plugins")
    assert_select "[role=alert]", text: /42001/
    assert_select "form[action=?]", admins_app_plugins_path(@a), count: 0
    assert_nil Rails.cache.read(direct_token_key(@a))
    assert Rails.cache.exist?(direct_token_key(@b))
    @read_error = {errcode: 0}
    get admins_plugins_path(app_id: @b.id)
    assert_select ".empty-title", "暂无插件"
    @read_error = {errcode: 0, plugin_list: nil}
    post admins_app_plugins_path(@b), params: {plugin_appid: "wxTool"}
    assert_match(/名单不完整/, flash[:alert])
    official = App.create!(provider: "wechat", app_type: "official_account", appid: "wxPub")
    post admins_app_plugins_path(official), params: {plugin_appid: "wxTool"}
    assert_response :not_found
    @b.update!(appsecret: nil)
    post admins_app_plugins_path(@b), params: {plugin_appid: "wxTool"}
    assert_match(/AppSecret|凭据/, flash[:alert])
    get admins_plugins_path(app_id: @b.id)
    assert_response :success
    assert_select "[role=alert]", /AppSecret/
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "plugin_#{role}", role: role)
      get admins_root_path
      assert_select "a[href=?]", admins_plugins_path, count: 0
      [[:get, admins_plugins_path], [:get, admins_app_path(@a, tab: "plugins")], [:post, admins_app_plugins_path(@a)],
        [:patch, admins_app_plugin_path(@a, "wxTool")], [:delete, admins_app_plugin_path(@a, "wxTool")]].each do |method, url|
        public_send(method, url)
        assert_response :forbidden
      end
    end
    assert_empty @writes
  end
end

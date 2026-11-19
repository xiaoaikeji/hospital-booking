require "test_helper"
require_relative "../support/wechat_http_test"

class WechatOpenPlatformAccountsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "open_admin", role: "super_admin")
    sign_in @admin
    @mini = wechat_app("A", "mini_program")
    @official = wechat_app("B", "official_account")
    @remote = {}
    @writes = []
    @stubs.post("/cgi-bin/open/get") do |env|
      appid = identity(env)
      response_for(@read_reply || (@remote[appid] ? { open_appid: @remote[appid] } : { errcode: 89002 }))
    end
    %w[create bind unbind].each do |action|
      @stubs.post("/cgi-bin/open/#{action}") do |env|
        appid = identity(env)
        body = JSON.parse(env.body)
        @writes << [action, appid, body["open_appid"]]
        result = case action
        when "create"
          @remote[appid] = "wxOpenMain"
          { open_appid: @remote[appid] }
        when "bind"
          @remote[appid] = @reported_account || body.fetch("open_appid")
          { errcode: 0 }
        when "unbind"
          assert_equal @remote.fetch(appid), body["open_appid"]
          @remote.delete(appid)
          { errcode: 0 }
        end
        raise Faraday::TimeoutError if @timeout == action
        response_for(@write_reply || result)
      end
    end
  end

  teardown { remove_wechat_stubs }

  test "通过小程序创建、公众号绑定和解绑均使用各自令牌；应用页签只读本地" do
    get new_admins_open_platform_account_path(app_id: @mini.id)
    assert_select "option[value=?][selected]", @mini.id, text: /微信小程序/
    post admins_open_platform_accounts_path, params: { app_id: @mini.id, name: "医院账号" }
    account = @mini.reload.open_platform_account
    assert_redirected_to admins_open_platform_account_path(account)
    assert_equal "医院账号", account.name
    assert_equal @admin, account.operator
    post admins_open_platform_account_bindings_path(account), params: {app_id: @official.id}
    assert_equal account, @official.reload.open_platform_account
    get admins_open_platform_accounts_path
    assert_select "tbody tr", text: /医院账号.*wxOpenMain.*2/m
    get admins_open_platform_accounts_path(q: "OpenMain")
    assert_select "a", text: "重置筛选"
    assert_select "tbody tr", text: /医院账号/
    get admins_open_platform_accounts_path(q: "不存在的医院")
    assert_select "h2", text: "没有找到匹配的开放平台账号"
    get admins_open_platform_account_path(account)
    assert_select "button[type=button]", text: "解绑", count: 2
    delete admins_open_platform_account_binding_path(account, @official)
    assert_nil @official.reload.open_platform_account
    assert_equal account, @mini.reload.open_platform_account
    @reads = 0
    get admins_app_path(@mini, tab: "open_platform")
    assert_select "a[href=?]", admins_open_platform_account_path(account), text: account.name
    assert_equal 0, @reads
    assert_equal [["create", @mini.appid, nil], ["bind", @official.appid, "wxOpenMain"], ["unbind", @official.appid, "wxOpenMain"]], @writes
    assert_equal 3, Log.where(target_id: [@mini.id, @official.id], action: %w[wechat.open_platform_create wechat.open_platform_bind wechat.open_platform_unbind], status: "success").count
  end

  test "创建超时后同应用阻止重发，取消授权保留记录，授权恢复后同步核实" do
    @timeout = "create"
    2.times do
      post admins_open_platform_accounts_path, params: {app_id: @mini.id, name: "医院账号"}
      assert_response :unprocessable_content
    end
    assert_equal 1, @writes.size
    assert_nil @mini.reload.open_platform_account
    assert OpenPlatformOperation.exists?(app: @mini)
    @mini.app_authorization.update!(refresh_token: nil)
    get admins_app_path(@mini, tab: "open_platform")
    assert_includes response.body, "结果待核实"
    assert_select "button", text: "同步绑定状态", count: 0
    patch admins_app_open_platform_path(@mini)
    assert_includes flash[:alert], "授权"
    @mini.app_authorization.update!(refresh_token: "restored")
    cache_token(@mini)
    patch admins_app_open_platform_path(@mini)
    assert_redirected_to admins_app_path(@mini, tab: "open_platform")
    assert_equal "医院账号", @mini.reload.open_platform_account.name
    assert_equal 1, @writes.size
    assert_not OpenPlatformOperation.exists?(app: @mini)
    assert_nil @official.reload.open_platform_account
  end

  test "绑定与解绑超时先核实微信结果，错误归属或残缺响应不能清除待核实状态" do
    @remote[@mini.appid] = "known-account"
    patch admins_app_open_platform_path(@mini)
    account = @mini.reload.open_platform_account
    @timeout = "bind"
    2.times { post admins_open_platform_account_bindings_path(account), params: {app_id: @official.id} }
    assert_equal ["bind"], @writes.map(&:first)
    @read_reply = { open_appid: "other-account", appid: @mini.appid }
    patch admins_app_open_platform_path(@official)
    assert flash[:alert]
    assert_nil @official.reload.open_platform_account
    assert OpenPlatformOperation.exists?(app: @official)
    @read_reply = { errcode: 0 }
    patch admins_app_open_platform_path(@official)
    assert flash[:alert]
    @read_reply = nil
    patch admins_app_open_platform_path(@official)
    assert_equal account, @official.reload.open_platform_account
    @timeout = "unbind"
    2.times { delete admins_open_platform_account_binding_path(account, @official) }
    assert_equal ["bind", "unbind"], @writes.map(&:first)
    assert_equal account, @official.reload.open_platform_account
    patch admins_app_open_platform_path(@official)
    assert_nil @official.reload.open_platform_account
    assert_equal account, @mini.reload.open_platform_account
  end

  test "共享同一开放平台编号只登记一条，其他目标账号的旧表单不能解绑或覆盖" do
    @remote[@mini.appid] = @remote[@official.appid] = "wxShared"
    post admins_open_platform_accounts_path, params: {app_id: @mini.id, name: "已登记的账号"}
    post admins_open_platform_accounts_path, params: {app_id: @official.id, name: "保留原来的名称"}
    assert_equal 1, OpenPlatformAccount.where(open_appid: "wxShared").count
    account = @official.reload.open_platform_account
    assert_equal "已登记的账号", account.name
    other = OpenPlatformAccount.create!(name: "其他账号", open_appid: "wxAnother", created_via_app: @mini, operator: @admin)
    delete admins_open_platform_account_binding_path(other, @official)
    assert_response :not_found
    @remote[@official.appid] = other.open_appid
    delete admins_open_platform_account_binding_path(account, @official)
    assert_includes flash[:alert], "绑定与本地不同"
    assert_empty @writes
    assert_equal account, @official.reload.open_platform_account
  end

  test "只允许超管管理本院微信授权应用；拒绝时不发微信写或暴露远端信息" do
    douyin = App.create!(provider: "douyin", appid: "ttOpen")
    patch admins_app_open_platform_path(douyin)
    assert_response :not_found
    sign_in @admin
    account = OpenPlatformAccount.create!(name: "已知", open_appid: "wxKnown", created_via_app: @mini, operator: @admin)
    @mini.app_authorization.update!(refresh_token: nil)
    post admins_open_platform_account_bindings_path(account), params: {app_id: @mini.id}
    assert_includes flash[:alert], "授权"
    assert_equal "failed", Log.last.status
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "open_#{role}", role: role)
      get admins_open_platform_accounts_path
      assert_response :forbidden
      get admins_open_platform_account_path(account)
      assert_response :forbidden
      post admins_open_platform_account_bindings_path(account), params: {app_id: @official.id}
      assert_response :forbidden
      patch admins_app_open_platform_path(@official)
      assert_response :forbidden
    end
    assert_empty @writes
  end

  test "微信 89000 按目标应用读回且与目标账号一致才接受；令牌错误不重写" do
    @write_reply = { errcode: 89000 }
    post admins_open_platform_accounts_path, params: {app_id: @mini.id}
    primary = @mini.reload.open_platform_account
    assert_equal "wxOpenMain", primary.open_appid
    other = OpenPlatformAccount.create!(name: "另一个开放平台", open_appid: "another", created_via_app: @mini, operator: @admin)
    @reported_account = other.open_appid
    post admins_open_platform_account_bindings_path(primary), params: {app_id: @official.id}
    assert_includes flash[:alert], "不一致"
    assert_nil @official.reload.open_platform_account
    patch admins_app_open_platform_path(@official)
    assert_equal other, @official.reload.open_platform_account
    @write_reply = {errcode: 40014}
    delete admins_open_platform_account_binding_path(other, @official)
    assert_includes flash[:alert], "40014"
    assert_equal 1, @writes.count { |operation| operation.first == "unbind" }
    assert_nil Rails.cache.read("apps/#{@official.id}/channel_token")
    assert Rails.cache.read("apps/#{@mini.id}/channel_token")
    assert_not OpenPlatformOperation.exists?(app: @official)
  end

  private

  def identity(env)
    appid = JSON.parse(env.body).fetch("appid")
    assert_includes [@mini.appid, @official.appid], appid
    assert_equal "token-#{appid}", env.params.fetch("access_token")
    @reads = @reads.to_i + 1 if env.url.path == "/cgi-bin/open/get"
    appid
  end

  def wechat_app(suffix, type)
    app = App.create!(provider: "wechat", app_type: type, appid: "wxOpen#{suffix}", nickname: "门诊#{suffix}")
    app.create_app_authorization!(refresh_token: "local")
    cache_token(app)
    app
  end

  def cache_token(app)
    Rails.cache.write("apps/#{app.id}/channel_token", { value: "token-#{app.appid}", revision: app.app_authorization.updated_at.to_f })
  end
end

require "test_helper"
require_relative "../support/wechat_http_test"

class WechatOfficialAccountLinksTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "links_super", role: "super_admin")
    sign_in @admin
    @official = App.create!(provider: "wechat", app_type: "official_account", appid: "wxOfficial", nickname: "院务")
    auth = @official.create_app_authorization!(refresh_token: "local-only")
    Rails.cache.write("apps/#{@official.id}/channel_token", { value: "local-official", revision: auth.updated_at.to_f })
    @mini = App.create!(provider: "wechat", appid: "wxTarget", nickname: "门诊")
    @rows = [{appid: "wxExternal", nickname: "历史号", status: 1}]
    @writes = @reads = 0
    @stubs.post("/cgi-bin/wxopen/wxamplinkget") do |env|
      assert_equal "local-official", Rack::Utils.parse_query(env.url.query)["access_token"]
      @reads += 1
      response_for(wxopens: {items: @rows})
    end
  end
  teardown { remove_wechat_stubs }

  def page_revision
    get admins_app_path(@official, tab: "links")
    assert_response :success
    css_select("input[name=revision]").first&.[]("value")
  end

  def link(rev)
    post admins_app_mini_program_links_path(@official), params: { mini_program_id: @mini.id, revision: rev, notify_users: "0", show_profile: "1" }
  end

  test "统一入口仅列本院公众号，实时关联、拒绝重试、解绑历史账号都按源公众号授权" do
    get admins_official_account_links_path
    assert_response :success
    assert_select "td", text: "wxOfficial"
    assert_select "td", text: "wxTarget", count: 0
    rev = page_revision
    assert_includes response.body, "未在本院登记"
    @stubs.post("/cgi-bin/wxopen/wxamplink") do |env|
      assert_equal({"appid"=>@mini.appid, "show_profile"=>1, "notify_users"=>0}, JSON.parse(env.body))
      @writes += 1
      @rows.reject! { |r| r[:appid] == @mini.appid }
      @rows << { appid: @mini.appid, nickname: "门诊", status: 2 }
      response_for(errcode: 0)
    end
    link(rev)
    assert_redirected_to admins_app_path(@official, tab: "links")
    assert_equal 1, @writes
    link(rev)
    assert_equal 1, @writes
    page_revision
    assert_includes response.body, "等待小程序管理员确认"
    assert_select "option[value=?]", @mini.id, count: 0
    @rows.last[:status] = 3
    rev = page_revision
    assert_select "option[value=?]", @mini.id
    link(rev)
    assert_equal 2, @writes
    @stubs.post("/cgi-bin/wxopen/wxampunlink") do |env|
      assert_equal({"appid"=>"wxExternal"}, JSON.parse(env.body))
      @rows.reject! { |r| r[:appid] == "wxExternal" }; response_for(errcode: 89018)
    end
    rev = page_revision
    delete admins_app_mini_program_link_path(@official, "wxExternal"), params: {revision: rev}
    assert_redirected_to admins_app_path(@official, tab: "links")
    assert_equal [@mini.appid], @rows.map { |r| r[:appid] }
    assert Log.exists?(source: "admin", action: "wechat.link_delete", target_id: @official.id, status: "success")
  end

  test "第二次申请被拒及微信侧解绑后仍可再选目标，历史操作不会重回待核实" do
    @stubs.post("/cgi-bin/wxopen/wxamplink") { @writes += 1; response_for(errcode: 0) }
    2.times do
      link(page_revision)
      op = WechatLinkOperation.find_by!(app: @official, mini_program_id: @mini.id)
      assert_equal "accepted", op.state
      @rows.reject! { |row| row[:appid] == @mini.appid }
      @rows << {appid: @mini.appid, status: 2}
      page_revision
      assert_equal "applied", op.reload.state
      @rows.last[:status] = 3
      page_revision
      assert_select "option[value=?]", @mini.id
      assert_select "h2", text: "待核实操作", count: 0
    end
    link(page_revision)
    @rows.last[:status] = 1
    page_revision
    @rows.pop
    page_revision
    assert_select "option[value=?]", @mini.id
    assert_select "h2", text: "待核实操作", count: 0
    assert_equal 3, @writes
  end

  test "两次读取之间本轮邀请再次被拒时，超管可核实已执行并重开候选" do
    @rows << {appid: @mini.appid, nickname: "门诊", status: 3}
    @stubs.post("/cgi-bin/wxopen/wxamplink") { @writes += 1; response_for(errcode: 0) }
    link(page_revision)
    op = WechatLinkOperation.find_by!(app: @official, mini_appid: @mini.appid)
    page_revision
    assert_select "option[value=?]", @mini.id, count: 0
    args = {operation_id: op.id, version: op.lock_version, outcome: "applied"}
    post verify_admins_app_mini_program_links_path(@official), params: args
    assert_equal "accepted", op.reload.state
    post verify_admins_app_mini_program_links_path(@official), params: args.merge(confirmed: "1")
    assert_equal "applied", op.reload.state
    page_revision
    assert_select "option[value=?]", @mini.id
    assert_equal 1, @writes
  end

  test "不确定的申请永久保留，管理员显式复查远端后才允许再试；注销授权仍能查本地历史" do
    rev = page_revision
    @stubs.post("/cgi-bin/wxopen/wxamplink") { @writes += 1; raise Faraday::TimeoutError }
    link(rev)
    op = WechatLinkOperation.find_by!(app: @official, mini_appid: @mini.appid)
    assert_equal "started", op.state
    2.times { link(rev) }
    assert_equal 1, @writes
    page_revision
    assert_select "h2", text: "待核实操作"
    args = { operation_id: op.id, version: op.lock_version.to_s, confirmed: "1" }
    post verify_admins_app_mini_program_links_path(@official), params: args.merge(outcome: "applied")
    assert_equal "started", op.reload.state
    post verify_admins_app_mini_program_links_path(@official), params: args.merge(outcome: "not_applied")
    assert_equal "not_applied", op.reload.state
    @official.app_authorization.update!(refresh_token: nil)
    reads = @reads
    get admins_app_path(@official, tab: "links")
    assert_response :success
    assert_includes response.body, "历史号"
    assert_select "button", text: "发起关联", count: 0
    assert_select "h2", text: "最近关联操作"
    assert_equal reads, @reads
  end

  test "微信返回相互矛盾或残缺的记录时显示上次快照并禁止写入" do
    rev = page_revision
    @rows << @rows.first.merge(status: 13)
    get admins_app_path(@official, tab: "links")
    assert_match(/存在重复记录/, response.body)
    assert_includes response.body, "历史号"
    assert_select "#official-link-create", count: 0
    link(rev)
    assert_match(/重复记录/, flash[:alert])
    assert_empty WechatLinkOperation.where(app: @official)
    @rows.replace([{appid: "wxExternal"}])
    get admins_app_path(@official, tab: "links")
    assert_match(/列表不完整/, response.body)
    assert_select "button", text: "解除关联", count: 0
  end

  test "服务端拒绝其他角色和错误平台类型、超管不能以未登记目标发起" do
    rev = page_revision
    post admins_app_mini_program_links_path(@official), params: { mini_program_id: @official.id, revision: rev }
    assert_match(/本院已登记/, flash[:alert])
    post admins_app_mini_program_links_path(@mini), params: {mini_program_id: @mini.id}
    assert_response :not_found
    sign_in Admin.create!(username: "link_cs", role: "customer_service")
    get admins_official_account_links_path
    assert_response :forbidden
    link(rev)
    assert_response :forbidden
    assert_empty WechatLinkOperation.where(app: @official)
  end
end

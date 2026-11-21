require "test_helper"
require_relative "../support/wechat_http_test"

class OfficialAccountMenusTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "menu_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wx1111111111111111 wx2222222222222222].map do |id|
      app = App.create!(appid: id, provider: "wechat", app_type: "official_account")
      configure_account(app)
      app
    end
    @mini = App.create!(appid: "wx3333333333333333", provider: "wechat")
    @remote = []
    @writes = []
    @delete_count = 0
    @stubs.get("/cgi-bin/get_current_selfmenu_info") { response_for(@snapshot || {selfmenu_info: {button: @remote}}) }
    @stubs.post("/cgi-bin/menu/create") do |env|
      @writes << [env.params["access_token"], JSON.parse(env.body)["button"]]
      raise Faraday::TimeoutError if @timeout
      response_for(errcode: @error || 0)
    end
    @stubs.get("/cgi-bin/menu/delete") { @delete_count += 1; response_for(errcode: 0) }
  end
  teardown { remove_wechat_stubs }

  def publish(buttons, app: @a, revision: nil, clear: false)
    post publish_admins_app_official_account_menu_path(app), params: {
      buttons: buttons, revision: revision || app.reload.official_account_menu&.revision || 0, clear: clear
    }, as: :json
  end

  def pull(accept: false)
    post pull_admins_app_official_account_menu_path(@a), params: {revision: @a.reload.official_account_menu&.revision || 0, accept: accept ? "1" : "0"}
    assert_redirected_to admins_official_account_menus_path(app_id: @a.id)
  end

  test "左侧公众号筛选、目标应用和超管权限覆盖所有接口" do
    get admins_official_account_menus_path(app_id: @a.id)
    assert_response :success
    assert_select "#official-menu-editor[data-editable=true]"
    assert_select "#menu-appid option[value=?]", @mini.appid
    get admins_app_path(@a)
    assert_select "a[href=?]", admins_official_account_menus_path(app_id: @a.id)
    @a.update!(appsecret: nil)
    get admins_official_account_menus_path(app_id: @a.id)
    assert_select "#official-menu-editor[data-editable=false]"
    assert_select "#menu-submit", count: 0
    publish([], clear: true)
    assert_response :unprocessable_content
    assert_equal 0, @delete_count
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "menu_#{role}", role: role)
      get admins_official_account_menus_path
      assert_response :forbidden
      [[:post,:publish],[:post,:pull],[:get,:articles],[:get,:image],[:post,:media]].each do |method,action|
        public_send(method, public_send("#{action}_admins_app_official_account_menu_path", @b))
        assert_response :forbidden
      end
    end
  end

  test "整套发布、旧表单、拒绝、明确清空均按公众号隔离" do
    node = {type: "miniprogram", name: "预约挂号", appid: @mini.appid, pagepath: "pages/booking/index"}
    publish([{ name: "就医", sub_button: [node] }])
    assert_response :success
    target, tree = @writes.sole
    assert_equal @a.appid, target
    assert_equal "https://mp.weixin.qq.com", tree.first["sub_button"].first["url"]
    publish([], clear: true, revision: "0")
    assert_response :unprocessable_content
    assert_equal 0, @delete_count
    @error = 40018
    publish([node.merge(name: "门诊")])
    assert_response :unprocessable_content
    assert_nil @a.reload.official_account_menu.pending_buttons
    assert_equal tree, @a.official_account_menu.buttons
    publish([])
    assert_response :unprocessable_content
    publish([], clear: true)
    assert_response :success
    assert_equal 1, @delete_count
    assert_empty @a.reload.official_account_menu.buttons
    assert_nil @b.reload.official_account_menu
    assert_equal 2, Log.where(target_id: @a.id, action: "wechat.menu_publish", status: "success").count
  end

  test "超时先读回，两次核实不同结果不能错误放行" do
    node = {name: "官网", type: "view", url: "https://example.test"}
    @timeout = true
    publish([node])
    assert_response :unprocessable_content
    assert response.parsed_body["pending"]
    publish([node])
    assert_equal 1, @writes.size
    pull
    assert_equal [], @a.reload.official_account_menu.observed_buttons
    @remote = [node.merge(name: "主页")]
    pull(accept: true)
    assert_predicate @a.reload.official_account_menu.pending_buttons, :present?
    pull(accept: true)
    assert_nil @a.reload.official_account_menu.pending_buttons
    assert_equal "主页", @a.official_account_menu.buttons.sole["name"]
    publish([node])
    @remote = [node]
    pull
    assert_nil @a.reload.official_account_menu.pending_buttons
    assert_equal 2, @writes.size
  end

  test "微信返回系统繁忙也先查单，已生效的菜单不再发送" do
    @error = -1
    node = { name: "官网", type: "view", url: "https://example.test" }
    publish([node])
    assert_response :unprocessable_content
    assert response.parsed_body["pending"]
    publish([node])
    assert_equal 1, @writes.size
    @remote = [node]
    pull
    assert_equal [node.stringify_keys], @a.reload.official_account_menu.buttons
    assert_nil @a.official_account_menu.pending_buttons
  end

  test "保留历史回复、微信原生文本和账号隔离，错误响应留住上次菜单" do
    @remote = [{name: "客服", type: "click", key: "CONTACT"}, {name: "地址", type: "text", value: "门诊一楼"}]
    pull
    nodes = @a.reload.official_account_menu.buttons
    assert_equal "门诊一楼", nodes.last["value"]
    publish(nodes)
    assert_response :unprocessable_content
    assert_empty @writes
    publish([nodes.first], app: @b)
    assert_response :unprocessable_content
    publish([nodes.first])
    assert_response :success
    assert_equal [nodes.first], @writes.sole.last
    @snapshot = {errcode: 0}
    pull
    assert_equal [nodes.first], @a.reload.official_account_menu.buttons
    @snapshot = {errcode: 42001}
    pull
    assert_nil Rails.cache.read(direct_token_key(@a))
    assert_equal @b.appid, Rails.cache.read(direct_token_key(@b))
  end

  test "读取到缺少动作字段的子菜单时保留整套原菜单" do
    original = {"type" => "view", "name" => "官网", "url" => "https://example.test/hospital"}
    publish([original])
    assert_response :success
    rev = @a.reload.official_account_menu.revision
    %w[view click media_id article_id miniprogram].each do |type|
      @remote = [{name: "门诊", sub_button: {list: [{name: "地址", type: type}]}}]
      pull
      assert_match(/菜单动作不完整/, flash[:alert])
      assert_equal [original], @a.reload.official_account_menu.buttons
      assert_equal rev, @a.official_account_menu.revision
    end
  end

  test "读回带空子列表的叶子后再次发布，链接、点击和素材原样传回微信" do
    @remote = [
      { name: "官网", type: "view", url: "https://example.test", sub_button: [] },
      { name: "服务", sub_button: { list: [
        { name: "客服", type: "click", key: "CONTACT", sub_button: { list: [] } },
        { name: "图片", type: "img", value: "image-from-wechat", sub_button: [] }
      ] } }
    ]
    pull
    expected = [
      { "name" => "官网", "type" => "view", "url" => "https://example.test" },
      { "name" => "服务", "sub_button" => [
        { "name" => "客服", "type" => "click", "key" => "CONTACT" },
        { "name" => "图片", "type" => "media_id", "media_id" => "image-from-wechat" }
      ] }
    ]
    assert_redirected_to admins_official_account_menus_path(app_id: @a.id)
    buttons = @a.reload.official_account_menu.buttons
    assert_equal expected, Wechat::MenuButtons.wire(buttons)
    publish(buttons)
    assert_response :success
    assert_equal expected, @writes.sole.last
  end

  test "层级、名称、小程序和网址不合法时微信写入为零" do
    node = {type: "view", name: "官网", url: "https://example.test/"}
    [[node]*4, [{name: "更多", sub_button: [node]*6}], [{name: "更多", sub_button: [{name: "嵌套", sub_button:[node]}]}],
      [node.merge(name: "名称超过四字")], [node.merge(url: "javascript:example")],
      [node.merge(type:"miniprogram", appid: @b.appid, pagepath: "pages/booking/index")]].each do |nodes|
      publish(nodes)
      assert_response :unprocessable_content
    end
    post publish_admins_app_official_account_menu_path(@a), params: {clear: true, revision: 0}, as: :json
    assert_response :unprocessable_content
    assert_empty @writes
    assert_equal 0, @delete_count
  end

  test "空菜单允许删除空应用，已有或待核实菜单保护应用" do
    app = App.create!(provider: "wechat", app_type: "official_account", appid: "wx4444444444444444")
    row = app.create_official_account_menu!(buttons: [{ "name"=>"官网", "type"=>"view", "url"=>"https://example.test" }])
    assert_not app.destroy
    row.update!(buttons: [], pending_buttons: [])
    assert_not app.reload.destroy
    row.update!(pending_buttons: nil)
    assert app.reload.destroy
    assert_not OfficialAccountMenu.exists?(row.id)
  end

  test "分页文章和上传素材按公众号读取，跨账号引用失败" do
    @stubs.post("/cgi-bin/freepublish/batchget") do |env|
      assert_equal({"offset"=>10,"count"=>10,"no_content"=>1}, JSON.parse(env.body))
      response_for(total_count: 11, item: [{article_id:"article-demo",content:{news_item:[{title:"门诊指南"}]}}])
    end
    get articles_admins_app_official_account_menu_path(@a), params: {page: 2}
    assert_response :success
    article = response.parsed_body["items"].sole.merge("name"=>"指南","type"=>"article_id")
    assert_equal "门诊指南", article["label"]
    @stubs.post("/cgi-bin/material/add_material") { |env| assert_equal "image", env.params["type"]; response_for(media_id: "media-demo") }
    png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIW2P4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")
    file = Rack::Test::UploadedFile.new(StringIO.new(png), "image/png", original_filename: "guide.png")
    post media_admins_app_official_account_menu_path(@a), params: {kind:"image",file:file}
    assert_response :success
    image = response.parsed_body.merge("name"=>"海报","type"=>"media_id")
    publish([article,image], app: @b)
    assert_response :unprocessable_content
    publish([article,image])
    assert_response :success
    assert_equal [{"name"=>"指南","type"=>"article_id","article_id"=>"article-demo"},{"name"=>"海报","type"=>"media_id","media_id"=>"media-demo"}], @writes.sole.last
    assert_not_includes @a.reload.official_account_menu.buttons.to_s, "proof"
    reads = 0
    @stubs.post("/cgi-bin/material/get_material") do |env|
      reads += 1
      assert_equal @a.appid, env.params["access_token"]
      [200, { "Content-Type"=>"image/png" }, png]
    end
    get image_admins_app_official_account_menu_path(@b), params: {media_id: "media-demo"}
    assert_response :not_found
    get image_admins_app_official_account_menu_path(@mini), params: {media_id: "media-demo"}
    assert_response :not_found
    get image_admins_app_official_account_menu_path(@a), params: {media_id: "media-demo"}
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal png, response.body.b
    assert_equal 1, reads
  end
end

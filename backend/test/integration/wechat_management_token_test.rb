require "test_helper"
require_relative "../support/wechat_http_test"

class WechatManagementTokenTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    sign_in Admin.create!(username: "token_admin", role: "super_admin")
    @target = authorized_app("A")
    @other = authorized_app("B")
    @refreshes = []
    Rails.cache.write("wechat/component/wxPlatform/token", "component")
    @stubs.post("/cgi-bin/component/api_authorizer_token") do |env|
      @refreshes << JSON.parse(env.body).fetch("authorizer_appid")
      response_for(authorizer_access_token: "fresh-A", expires_in: 7200)
    end
  end

  teardown { remove_wechat_stubs }

  test "查额度、查版本和截图只清本次过期的令牌，保留其他应用及并发新令牌" do
    quota_tokens, version_tokens, screenshot_tokens = [], [], []
    @stubs.get("/wxa/queryquota") do |env|
      quota_tokens << env.params.fetch("access_token")
      response_for(quota_tokens.last == "cached-A" ? { errcode: 42001 } : { rest: 12 })
    end
    @stubs.post("/wxa/getversioninfo") do |env|
      version_tokens << env.params.fetch("access_token")
      response_for(version_tokens.last == "cached-A" ? { errcode: 40014 } : { release_info: { release_version: "2.1" } })
    end
    image = File.binread(file_fixture("storage.png"))
    @stubs.post("/cgi-bin/material/get_material") do |env|
      screenshot_tokens << env.params.fetch("access_token")
      if screenshot_tokens.last == "cached-A"
        cache_token(@target, "concurrently-refreshed-A")
        response_for(errcode: 40001)
      else
        [200, { "Content-Type" => "image/png" }, image]
      end
    end
    quota = admins_mini_program_releases_path(app_id: @target.id, quota: "1")
    version = admins_app_path(@target, tab: "releases", verify_version: "1")
    [quota, version].each do |url|
      cache_token(@target, "cached-A")
      get url
      assert_response :success
      assert_nil cached_token(@target)
      get url
      assert_response :success
      assert_equal "fresh-A", cached_token(@target)
    end
    assert_equal ["cached-A", "fresh-A"], quota_tokens
    assert_equal ["cached-A", "fresh-A"], version_tokens

    operator = Admin.find_by!(username: "token_admin")
    audit = @target.mini_program_audits.create!(operator: operator, audit_id: "408", version: "2.1", description: "审退版",
      status: "rejected", previous_status: "active", rejection_screenshots: ["fixture-screenshot"])
    cache_token(@target, "cached-A")
    path = screenshot_admins_app_audit_path(@target, audit, index: 0)
    get path
    assert_response :service_unavailable
    assert_equal "concurrently-refreshed-A", cached_token(@target)
    get path
    assert_response :success
    assert_equal image, response.body.b
    assert_equal ["cached-A", "concurrently-refreshed-A"], screenshot_tokens
    assert_equal [@target.appid, @target.appid], @refreshes
    assert_equal "cached-B", cached_token(@other)
  end

  test "域名页分别读取两组，第一组令牌过期后第二组使用新令牌，刷新后都可以编辑" do
    calls = []
    Wechat::MiniProgramDomainClient::PATHS.each do |kind, path|
      @stubs.post(path) do |env|
        token = env.params.fetch("access_token")
        calls << [kind, token]
        field = kind == "server" ? "requestdomain" : "webviewdomain"
        response_for(token == "cached-A" ? { errcode: 40014 } : { field => [] })
      end
    end
    get admins_app_path(@target, tab: "domains")
    assert_response :success
    assert_includes response.body, "40014"
    assert_select "form[action=?]", admins_app_server_domain_path(@target), count: 0
    assert_select "form[action=?]", admins_app_business_domain_path(@target), count: 1
    get admins_app_path(@target, tab: "domains")
    assert_select "form[action=?]", admins_app_server_domain_path(@target), count: 1
    assert_equal [["server","cached-A"], ["business","fresh-A"], ["server","fresh-A"], ["business","fresh-A"]], calls
    assert_equal [@target.appid], @refreshes
    assert_equal "cached-B", cached_token(@other)
  end

  test "域名写请求被拒只发一次，失败返回时保留并发写入的新令牌" do
    writes = []
    @stubs.post("/wxa/modify_domain") do |env|
      if JSON.parse(env.body).fetch("action") == "set"
        writes << env.params.fetch("access_token")
        cache_token(@target, "concurrently-refreshed")
        response_for(errcode: 42001)
      else
        response_for(requestdomain: [])
      end
    end
    @stubs.post("/wxa/setwebviewdomain") { response_for(webviewdomain: []) }
    get admins_app_path(@target, tab: "domains")
    revision = css_select("#server-revision").sole["value"]
    patch admins_app_server_domain_path(@target), params: { revision: revision, domains: { requestdomain: "https://hospital.example" } }
    assert_redirected_to admins_app_path(@target, tab: "domains")
    assert_includes flash[:alert], "42001"
    assert_equal "failed", Log.last.status
    assert_equal ["cached-A"], writes
    assert_equal "concurrently-refreshed", cached_token(@target)
    assert_equal "cached-B", cached_token(@other)
    assert_empty @refreshes
  end

  test "类目目录的独立错误仍清理令牌并保留已设类目，刷新后可以添加" do
    calls = []
    @stubs.get("/cgi-bin/wxopen/getcategory") do |env|
      calls << ["settings", env.params.fetch("access_token")]
      response_for(categories: [{first: 2, second: 3, first_name: "医疗", second_name: "医院"}], quota: 2)
    end
    @stubs.get("/cgi-bin/wxopen/getallcategories") do |env|
      token = env.params.fetch("access_token")
      calls << ["catalog", token]
      response_for(token == "cached-A" ? { errcode: 40001 } : { categories_list: { categories: catalog } })
    end
    get admins_app_path(@target, tab: "categories")
    assert_response :success
    assert_includes response.body, "医院"
    assert_includes response.body, "40001"
    assert_select "button", text: "新增服务类目", count: 0
    assert_nil cached_token(@target)
    get admins_app_path(@target, tab: "categories")
    assert_select "button", text: "新增服务类目", count: 1
    assert_equal [["settings","cached-A"], ["catalog","cached-A"], ["settings","fresh-A"], ["catalog","fresh-A"]], calls
    assert_equal [@target.appid], @refreshes
    assert_equal "cached-B", cached_token(@other)
  end

  test "类目添加明确拒绝过期令牌，只登记一次失败和一个写请求；手动再发前重新读取" do
    @stubs.get("/cgi-bin/wxopen/getcategory") { response_for(categories: [], quota: 2) }
    @stubs.get("/cgi-bin/wxopen/getallcategories") { response_for(categories_list: { categories: catalog }) }
    writes = []
    @stubs.post("/cgi-bin/wxopen/addcategory") do |env|
      writes << env.params.fetch("access_token")
      response_for(errcode: writes.last == "cached-A" ? 42001 : 0)
    end
    get admins_app_path(@target, tab: "categories")
    params = { revision: css_select("[name=revision]").sole["value"], first: 10, second: 20 }
    post admins_app_categories_path(@target), params: params, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "42001"
    assert_nil response.parsed_body["verify"]
    assert_equal 1, Log.where(target_type: "App", target_id: @target.id, action: "wechat.category_add", status: "failed").count
    assert_equal ["cached-A"], writes
    assert_nil cached_token(@target)
    post admins_app_categories_path(@target), params: params, as: :json
    assert_response :success
    assert_equal ["cached-A", "fresh-A"], writes
    assert_equal [@target.appid], @refreshes
    assert_equal "cached-B", cached_token(@other)
  end

  test "已设类目读取和资质上传分别遇到令牌错误，上传不重放也不发起类目申请" do
    @stubs.get("/cgi-bin/wxopen/getcategory") do |env|
      response_for(env.params.fetch("access_token") == "cached-A" ? { errcode: 40014 } : { categories: [], quota: 2 })
    end
    nodes = catalog
    nodes.last[:qualify] = { exter_list: [{ inner_list: [{ name: "医院资质" }] }] }
    @stubs.get("/cgi-bin/wxopen/getallcategories") { response_for(categories_list: { categories: nodes }) }
    get admins_app_path(@target, tab: "categories")
    assert_response :success
    assert_includes response.body, "40014"
    assert_nil cached_token(@target)
    get admins_app_path(@target, tab: "categories")
    assert_select "button", text: "新增服务类目", count: 1

    uploads = []
    @stubs.post("/cgi-bin/media/upload") do |env|
      uploads << env.params.fetch("access_token")
      response_for(errcode: 40001)
    end
    png = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1A\n".b + "0" * 80), "image/png", original_filename: "test.png")
    post admins_app_categories_path(@target), params: {
      revision: css_select("[name=revision]").sole["value"], first: 10, second: 20,
      certificates: { "0" => png }, expire_modes: { "0" => "permanent" }
    }, headers: { "ACCEPT" => "application/json" }
    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "40001"
    assert_nil response.parsed_body["verify"]
    assert_equal ["fresh-A"], uploads
    assert_not Log.exists?(target_type: "App", target_id: @target.id, action: "wechat.category_add", status: "started")
    assert_nil cached_token(@target)
    assert_equal "cached-B", cached_token(@other)
  end

  test "提审预检遇到过期令牌只读一次，下一次再读回已通过类目" do
    reads = []
    @stubs.get("/cgi-bin/wxopen/getcategory") do |env|
      reads << env.params.fetch("access_token")
      response_for(reads.last == "cached-A" ? { errcode: 42001 } : {
        categories: [{ first: 1, second: 2, first_name: "医疗", second_name: "医院", audit_status: 3 }]
      })
    end
    preflight = WechatPlatform::AuditPreflight.new(@target)
    assert_empty preflight.items
    assert_nil cached_token(@target)
    assert_empty @refreshes
    assert_equal [{ first_class: "医疗", second_class: "医院", first_id: 1, second_id: 2 }], preflight.items
    assert_equal ["cached-A", "fresh-A"], reads
    assert_equal [@target.appid], @refreshes
    assert_equal "cached-B", cached_token(@other)
  end

  private

  def authorized_app(suffix)
    app = App.create!(provider: "wechat", appid: "wxToken#{suffix}")
    app.create_app_authorization!(refresh_token: "test-only")
    cache_token(app, "cached-#{suffix}")
    app
  end

  def cache_token(app, value)
    Rails.cache.write("apps/#{app.id}/channel_token", {value: value, revision: app.app_authorization.updated_at.to_f})
  end

  def cached_token(app) = Rails.cache.read("apps/#{app.id}/channel_token")&.fetch(:value)

  def catalog
    [{id: 10, level: 1, name: "公共服务"}, {id: 20, level: 2, father: 10, name: "信息展示"}]
  end
end

require "test_helper"
require_relative "../support/wechat_http_test"

class WechatCategoriesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "category_admin", role: "super_admin")
    sign_in @admin
    @hospital_app = App.create!(provider: "wechat", appid: "wxCategory")
    auth = @hospital_app.create_app_authorization!(refresh_token: "local-test", original_id: "gh_category")
    Rails.cache.write("apps/#{@hospital_app.id}/channel_token", { value: "category-test", revision: auth.updated_at.to_f })
    @rows = []
    @quota = 5
    @uploads = @writes = 0
    @stubs.get("/cgi-bin/wxopen/getcategory") { response_for(categories: @rows, quota: @quota, category_limit: 5) }
    nodes = [{id: 11, level: 1, name: "公共服务"}, {id: 30, level: 2, father: 11, name: "信息展示"}, {id: 10, level: 1, name: "医疗"}, {id: 20, level: 2, father: 10, name: "医院",
      qualify: {exter_list: [{inner_list: [{name: "机构证明"}]}]}}]
    @stubs.get("/cgi-bin/wxopen/getallcategories") { response_for(categories_list: { categories: nodes }) }
    @stubs.post("/cgi-bin/media/upload") do |env|
      @uploads += 1
      assert_includes env.request_headers["Content-Type"], "multipart/form-data"
      response_for(media_id: "secret-media")
    end
  end
  teardown { remove_wechat_stubs }

  def revision
    get admins_app_path(@hospital_app, tab: "categories")
    assert_response :success
    css_select('[name=revision]').first&.[]("value")
  end

  def add(rev, bytes: nil)
    params = {revision: rev, first: "10", second: "20", expire_modes: {"0" => "permanent"}, audit_urgent: "1"}
    if bytes
      file = Rack::Test::UploadedFile.new(StringIO.new(bytes.b), "image/png", original_filename: "机构证明.png")
      params[:certificates] = {"0" => file}
    end
    post admins_app_categories_path(@hospital_app), params: params, headers: { "ACCEPT" => "application/json" }
  end

  test "类目写操作验证真实图片、资质和额度，微信拒绝保留输入，成功日志隔离敏感数据" do
    rev = revision
    add(rev)
    assert_response :unprocessable_content
    add(rev, bytes: "wrong")
    assert_response :unprocessable_content
    assert_equal 0, @uploads
    @stubs.post("/cgi-bin/wxopen/addcategory") do |env|
      @writes += 1
      row = JSON.parse(env.body).fetch("categories").sole
      assert_equal({"key" => "机构证明", "value" => "secret-media", "is_permanent" => 1}, row.fetch("certicates").sole)
      assert_equal [10,20,1], row.values_at("first","second","audit_urgent")
      if @writes == 1
        response_for(errcode: 40007)
      else
        @rows << {"first"=>10, "second"=>20, "first_name"=>"医疗", "second_name"=>"医院", "audit_status"=>1}
        response_for(errcode: 0)
      end
    end
    png = "\x89PNG\r\n\x1A\n".b + "0"*80
    add(rev, bytes: png)
    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "已经失效"
    add(rev, bytes: png)
    assert_response :success
    add(rev, bytes: png)
    assert_response :unprocessable_content
    assert_equal 2, @writes
    logs = Log.where(action: "wechat.category_add").pluck(:details).to_json
    assert_not_includes logs, "secret-media"
    assert_not_includes logs, "机构证明.png"

    @stubs.post("/cgi-bin/wxopen/deletecategory") { @rows.clear; response_for(errcode: 0) }
    remove_revision = revision
    delete admins_app_category_path(@hospital_app, "10-20"), params: {revision: remove_revision}
    assert_redirected_to admins_app_path(@hospital_app, tab: "categories")
    assert_empty @rows
    @quota = 0
    get admins_app_path(@hospital_app, tab: "categories")
    assert_select "button", text: "新增服务类目", count: 0
  end

  test "类目写超时后显式核实、禁止重复提交，非超管和非小程序不能代操作" do
    rev = revision
    @stubs.post("/cgi-bin/wxopen/addcategory") { @writes += 1; raise Faraday::TimeoutError }
    png = "\x89PNG\r\n\x1A\n".b + "0"*60
    add(rev, bytes: png)
    assert_response :unprocessable_content
    add(rev, bytes: png)
    assert_equal 1, @writes
    get admins_app_path(@hospital_app, tab: "categories")
    id = css_select('[name=operation_id]').sole["value"]
    post verify_admins_app_categories_path(@hospital_app), params: { operation_id: id, confirmed: "1", outcome: "applied" }
    assert_match(/不一致/, flash[:alert])
    post verify_admins_app_categories_path(@hospital_app), params: { operation_id: id, confirmed: "1", outcome: "not_applied" }
    assert_match(/已核实/, flash[:notice])
    sign_in Admin.create!(username: "category_ops", role: "operator")
    add(rev)
    assert_response :forbidden
    sign_in @admin
    oa = App.create!(provider: "wechat", app_type: "official_account", appid: "wxOA")
    post admins_app_categories_path(oa), params: {}
    assert_response :not_found
  end

  test "无需资质的类目不传素材和加急，按日期的资质使用北京时间当日末秒" do
    rev = revision
    @stubs.post("/cgi-bin/wxopen/addcategory") do |env|
      row = JSON.parse(env.body).fetch("categories").sole
      assert_equal({"first" => 11, "second" => 30, "certicates" => []}, row)
      response_for(errcode: 0)
    end
    post admins_app_categories_path(@hospital_app), params: { first: "11", second: "30", revision: rev, audit_urgent: "1" }, as: :json
    assert_response :success
    assert_equal 0, @uploads

    rev = revision
    @stubs.post("/cgi-bin/wxopen/addcategory") do |env|
      cert = JSON.parse(env.body).dig("categories",0,"certicates",0)
      assert_equal Time.find_zone!("Asia/Shanghai").local(2030,8,9,23,59,59).to_i, cert["expire_time"]
      assert_not cert.key?("is_permanent")
      response_for(errcode: 0)
    end
    png = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1A\n".b + "0"*80), "image/png", original_filename: "test.png")
    post admins_app_categories_path(@hospital_app), params: { revision: rev, first: "10", second: "20", expire_times: {"0" => "2030-08-09"}, certificates: {"0" => png} }, headers: {"ACCEPT" => "application/json"}
    assert_response :success
  end

  test "类目回调校验授权应用并去重，不改变代码审核和应用运行状态" do
    now = Time.current.to_i
    xml = "<xml><ToUserName>gh_category</ToUserName><MsgType>event</MsgType><Event>wxa_category_audit</Event><first>10</first><second>20</second><ret>3</ret><CreateTime>#{now}</CreateTime></xml>"
    Sidekiq.testing!(:fake) do
      2.times { signed_push("/api/wechat/component/apps/wxCategory/messages", xml) }
      WechatPlatform::CategoryAuditEventWorker.drain
    end
    assert_equal 1, Log.where(source: "system", action: "wechat.category_audit", target_id: @hospital_app.id).count
    assert_empty @hospital_app.mini_program_audits
  end
end

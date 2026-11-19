require "test_helper"
require_relative "../support/wechat_http_test"

class WechatLocationInterfacesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "location_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxLocationA wxLocationB].map do |id|
      app = App.create!(provider: "wechat", appid: id)
      auth = app.create_app_authorization!(refresh_token: "local-refresh")
      Rails.cache.write("apps/#{app.id}/channel_token", { value: id, revision: auth.updated_at.to_f })
      app
    end
    @rows = {
      @a.appid => [{"api_name"=>"wx.chooseAddress", "api_ch_name"=>"wx.chooseAddress", "api_desc"=>"收件地址",
                    "api_link"=>"/miniprogram/dev/api/open-api/address/wx.chooseAddress.md"},
                   {"api_name"=>"wx.choosePoi", "status"=>4, "audit_id"=>100, "fail_reason"=>"请提供选点页面"},
                   {"api_name"=>"wx.getLocation", "status"=>2}, {"api_name"=>"wx.chooseLocation", "status"=>3},
                   {"api_name"=>"wx.getFuzzyLocation", "status"=>5}, {"api_name"=>"wx.futureApi", "status"=>17}],
      @b.appid => []
    }
    @stubs.get("/wxa/security/get_privacy_interface") { |env| response_for(@read_error || { interface_list: @rows.fetch(env.params.fetch("access_token")) }) }
    @writes = []
    @stubs.post("/wxa/security/apply_privacy_interface") do |env|
      @writes << [env.params.fetch("access_token"), JSON.parse(env.body)]
      raise Faraday::TimeoutError if @timeout
      response_for(@reply || {errcode: 0, audit_id: 9876})
    end
  end
  teardown { remove_wechat_stubs }

  test "微信列表及动态接口、权限、空态和旧表单均按本应用判断" do
    assert_no_difference("Log.count") { get admins_app_path(@a, tab: "location") }
    assert_select "table tbody tr", 6
    assert_select "td", /收件地址/
    assert_select "td a[href=?]", "https://developers.weixin.qq.com/miniprogram/dev/api/open-api/address/wx.chooseAddress.html"
    get admins_app_path(@a, tab: "location", view: "apply")
    assert_equal %w[wx.getLocation wx.chooseLocation wx.getFuzzyLocation wx.futureApi], css_select("select option[disabled]").map { |o| o["value"] }
    @rows[@a.appid][0]["status"] = 3
    %w[wx.chooseAddress wx.getLocation wx.futureApi wx.notListed].each { |name| submit(@a, name) }
    assert_empty @writes
    get admins_app_path(@b, tab: "location")
    assert_select ".empty-title", /没有|未列出/
    @read_error = {errcode: 0}
    get admins_app_path(@b, tab: "location")
    assert_select ".empty-title", /未列出/
    @read_error = {interface_list: nil}
    get admins_app_path(@b, tab: "location")
    assert_select "[role=alert]", /列表不完整/
    @read_error = {errcode: 42001}
    get admins_app_path(@a, tab: "location", view: "apply")
    assert_select "[role=alert]", /42001/
    assert_select "a[href=?]", admins_app_path(@a, tab: "location", view: "apply"), text: "重新读取"
    assert_nil Rails.cache.read("apps/#{@a.id}/channel_token")
    assert Rails.cache.exist?("apps/#{@b.id}/channel_token")
    official = App.create!(provider: "wechat", app_type: "official_account", appid: "wxPublic")
    get admins_app_path(official)
    assert_select ".nav-link", text: "地理位置", count: 0
    submit(official, "wx.chooseAddress")
    assert_response :not_found
    @b.app_authorization.update!(refresh_token: nil)
    submit(@b, "wx.chooseAddress")
    assert_match(/授权/, flash[:alert])
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "location_#{role}", role: role)
      get admins_app_path(@a, tab: "location")
      assert_response :forbidden
      submit(@a, "wx.chooseAddress")
      assert_response :forbidden
      post verify_admins_app_location_interface_application_path(@a, 1)
      assert_response :forbidden
    end
    assert_empty @writes
  end

  test "拒绝后保留表单，重新申请拿到单号，微信尚未刷新时不能重复提交" do
    name = "wx.choosePoi"
    @reply = {errcode: 61036}
    submit(@a, name)
    assert_redirected_to admins_app_path(@a, tab: "location", view: "apply")
    follow_redirect!
    assert_select "[role=alert]", /61036.*服务类目/
    assert_select "option[selected][value=?]", name
    assert_select "textarea", "在地图选择目标院区"
    assert_equal 61036, @a.location_interface_applications.sole.error_code
    assert_equal 61036, Log.where(action: "wechat.location_apply", status: "failed").sole.details["error_code"]
    @reply = nil
    submit(@a, name)
    assert_redirected_to admins_app_path(@a, tab: "location")
    assert_match(/9876/, flash[:notice])
    submit(@a, name)
    assert_equal [@a.appid, @a.appid], @writes.map(&:first)
    assert_equal({"api_name"=>name, "content"=>"在地图选择目标院区"}, @writes.last.last)
    assert_equal [@admin.id, "9876"], @a.location_interface_applications.last.attributes.values_at("operator_id", "audit_id")
    @rows[@a.appid][1]["audit_id"] = 9876
    submit(@a, name)
    assert_equal 3, @writes.size
    assert_empty @b.location_interface_applications
    assert_not_includes Log.where(action: "wechat.location_apply").pluck(:details).to_s, "在地图选择目标院区"
  end

  test "受理不明时必须核实同一个小程序的最新状态，旧核实页不能放开重试" do
    @timeout = true
    submit(@a, "wx.choosePoi")
    assert_redirected_to admins_app_path(@a, tab: "location")
    attempt = @a.location_interface_applications.sole
    assert attempt.uncertain?
    submit(@a, "wx.choosePoi")
    assert_equal 1, @writes.size
    get admins_app_path(@a, tab: "location")
    observed = css_select("[name=observed_review]").first["value"]
    post verify_admins_app_location_interface_application_path(@b, attempt), params: {confirmed: "1", observed_review: observed}
    assert_response :not_found
    @rows[@a.appid][1]["status"] = 3
    post verify_admins_app_location_interface_application_path(@a, attempt), params: {confirmed: "1", observed_review: observed}
    assert_match(/状态已更新/, flash[:alert])
    assert attempt.reload.uncertain?
    get admins_app_path(@a, tab: "location")
    post verify_admins_app_location_interface_application_path(@a, attempt), params: {confirmed: "1", observed_review: css_select("[name=observed_review]").first["value"]}
    assert_equal "verified", attempt.reload.state
    submit(@a, "wx.choosePoi")
    assert_equal 1, @writes.size
    @timeout = false
    @reply = {errcode: 0}
    submit(@a, "wx.chooseAddress")
    other = @a.location_interface_applications.last
    assert other.uncertain?
    get admins_app_path(@a, tab: "location")
    post verify_admins_app_location_interface_application_path(@a, other), params: {confirmed: "1", observed_review: css_select("[name=observed_review]").first["value"]}
    assert_equal "not_accepted", other.reload.state
    @reply = nil
    submit(@a, "wx.chooseAddress")
    assert_equal "accepted", @a.location_interface_applications.last.state
  end

  test "材料先验证内容再上传，微信链接只允许读取对应应用的单张图片" do
    invalid = Rack::Test::UploadedFile.new(StringIO.new("not an image".b), "image/png", original_filename: "other.png")
    assert_no_difference("ActiveStorage::Blob.count") { submit(@a, "wx.choosePoi", pictures: [image_file, invalid]) }
    assert_empty @writes
    post admins_app_location_interface_applications_path(@a), params: {location_application: {api_name: "wx.choosePoi", content: "字"*301}}
    assert_match(/300/, flash[:alert])
    submit(@a, "wx.choosePoi", pictures: Array.new(11) { image_file })
    assert_match(/最多 10 张/, flash[:alert])
    assert_empty @writes
    submit(@a, "wx.choosePoi", pictures: [image_file, image_file])
    urls = @writes.sole.last.fetch("pic_list")
    assert_equal 2, urls.uniq.size
    attempt = @a.location_interface_applications.sole
    assert_equal 2, attempt.pictures.blobs.pluck(:key).uniq.size
    assert_match(/\A\d{10}[a-f0-9]{6}\.png\z/, attempt.pictures.first.blob.key)
    sign_out @admin
    uri = URI.parse(urls.first)
    get uri.request_uri
    assert_response :success
    assert_equal File.binread(file_fixture("storage.png")), response.body.b
    get uri.path
    assert_response :not_found
    get uri.request_uri.sub("/apps/#{@a.id}/", "/apps/#{@b.id}/")
    assert_response :not_found
    get URI.parse(urls.last).path + "?" + uri.query
    assert_response :not_found
    travel 31.days do
      get uri.request_uri
      assert_response :not_found
    end
    @a.app_authorization.update!(refresh_token: nil)
    get uri.request_uri
    assert_response :not_found
    assert_no_match(/review_token|storage\.png|在地图选择目标院区/, Log.where(action: "wechat.location_apply").pluck(:details).to_s)
  end

  private

  def submit(app, name, pictures: [])
    post admins_app_location_interface_applications_path(app), params: {
      location_application: {api_name: name, content: "在地图选择目标院区", pictures: pictures}
    }
  end

  def image_file = Rack::Test::UploadedFile.new(file_fixture("storage.png"), "image/png")
end

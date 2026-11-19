require "test_helper"
require_relative "../support/wechat_http_test"

class WechatProfilesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "profile_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxProfileA wxProfileB].map do |id|
      app = App.create!(provider: "wechat", appid: id, nickname: "本地应用")
      auth = app.create_app_authorization!(refresh_token: "local-refresh")
      Rails.cache.write("apps/#{app.id}/channel_token", {value: id, revision: auth.updated_at.to_f})
      app
    end
    @profiles = [@a, @b].to_h do |app|
      [app.appid, { "appid" => app.appid, "nickname_info" => {"nickname" => "微信名称#{app.appid}", "modify_quota" => 2, "modify_used_count" => 0},
        "signature_info" => {"signature" => "医院账号简介"}, "head_image_info" => {} }]
    end
    @stubs.post("/cgi-bin/account/getaccountbasicinfo") do |env|
      response_for(@read_error || @profiles.fetch(env.params.fetch("access_token")))
    end
    @writes = []
  end
  teardown { remove_wechat_stubs }

  test "名称检测只读，命中、未命中、没有接口权限或缺失结果各自显示" do
    @stubs.post("/cgi-bin/wxverify/checkwxverifynickname") do |env|
      assert_equal @a.appid, env.params.fetch("access_token")
      assert_equal({"nick_name" => "院内导诊"}, JSON.parse(env.body))
      response_for(@check_result)
    end
    assert_no_difference("Log.count") do
      [[{hit_condition: true, wording: "需提供商标材料"}, "需提供商标材料"],
       [{hit_condition: false}, "未命中微信名称规则"], [{errcode: 41033}, "仅支持通过接口创建"],
       [{errcode: 0}, "未返回名称检测结果"]].each do |result, message|
        @check_result = result
        get admins_app_path(@a, tab: "profile", nickname: "院内导诊")
        assert_response :success
        assert_includes response.body, message
        assert_select "dd", /微信名称wxProfileA.*本年已改 0 \/ 2 次/
        assert_select "#signature", text: "医院账号简介"
      end
    end
    assert_equal "本地应用", @a.reload.nickname
  end

  test "被拒简介原地保留，超时后核实微信现值，旧表单和其他应用不能重复修改" do
    @stubs.post("/cgi-bin/account/modifysignature") do |env|
      id = env.params.fetch("access_token")
      text = JSON.parse(env.body).fetch("signature")
      @writes << id
      next response_for(errcode: 53201) if @reject
      @profiles.fetch(id).fetch("signature_info")["signature"] = text
      raise Faraday::TimeoutError if @timeout
      response_for(errcode: 0)
    end
    rev = revision(@a, "signature")
    arguments = {field: "signature", revision: rev, signature: "更新后门诊预约简介"}
    @reject = true
    patch admins_app_profile_path(@a), params: arguments
    assert_redirected_to admins_app_path(@a, tab: "profile")
    follow_redirect!
    assert_select "[role=alert]", /限制词/
    assert_select "#signature", text: arguments[:signature]
    @reject = false
    @timeout = true
    patch admins_app_profile_path(@a), params: arguments
    assert_match(/核实后再操作/, flash[:alert])
    patch admins_app_profile_path(@a), params: arguments
    assert_match(/资料已变化/, flash[:alert])
    patch admins_app_profile_path(@b), params: arguments
    assert_match(/资料已变化/, flash[:alert])
    assert_equal [@a.appid, @a.appid], @writes
    assert_equal "医院账号简介", @profiles[@b.appid]["signature_info"]["signature"]
    @timeout = false
    patch admins_app_profile_path(@a), params: arguments.merge(signature: "再次更新科室简介", revision: revision(@a, "signature"))
    assert_match(/已提交微信/, flash[:notice])
    logs = Log.where(action: "wechat.profile_signature", actor_id: @admin.id)
    assert_equal [@a.id], logs.where(status: "success").pluck(:target_id)
    assert_not_includes logs.pluck(:details).to_json, arguments[:signature]
  end

  test "微信头像先验文件再换素材，令牌按应用隔离，修改必须收到明确结果" do
    rev = revision(@a, "head_image")
    @stubs.post("/cgi-bin/media/upload") do |env|
      assert_equal({"access_token" => @a.appid, "type" => "image"}, env.params)
      assert_includes env.request_headers["Content-Type"], "multipart/form-data"
      @writes << :upload
      response_for(@upload_error || {media_id: "private-media"})
    end
    @stubs.post("/cgi-bin/account/modifyheadimage") do |env|
      assert_equal @a.appid, env.params.fetch("access_token")
      assert_equal({"head_img_media_id" => "private-media", "x1" => "0", "y1" => "0", "x2" => "1", "y2" => "1"}, JSON.parse(env.body))
      @writes << :modify
      response_for(@result || {errcode: 0})
    end
    submit = lambda do |bytes|
      image = Rack::Test::UploadedFile.new(StringIO.new(bytes), "image/png", original_filename: "private-filename.png")
      patch admins_app_profile_path(@a), params: {field: "head_image", revision: rev, head_image: image}
    end
    png = "\x89PNG\r\n\x1A\n".b + "0" * 80
    submit.call("fake png")
    submit.call("x" * (2.megabytes + 1))
    assert_empty @writes
    @upload_error = {errcode: 40007}
    submit.call(png)
    assert_equal [:upload], @writes
    @upload_error = nil
    @result = {}
    submit.call(png)
    assert_match(/未确认修改结果/, flash[:alert])
    @result = nil
    submit.call(png)
    assert_match(/已提交微信/, flash[:notice])
    assert_equal [:upload, :upload, :modify, :upload, :modify], @writes
    logs = Log.where(action: "wechat.profile_head_image", target_id: @a.id)
    assert_equal 1, logs.where(status: "success").count
    assert_no_match(/private-media|private-filename/, logs.pluck(:details).to_json)
    @read_error = {errcode: 42001}
    get admins_app_path(@a, tab: "profile")
    assert_select "[role=alert]", /42001/
    assert_select "#signature", count: 0
    assert_nil Rails.cache.read("apps/#{@a.id}/channel_token")
    assert Rails.cache.exist?("apps/#{@b.id}/channel_token")
  end

  test "账号资料只对已授权微信小程序可写，其他角色不能读取或提交" do
    @read_error = {"appid" => @b.appid, "nickname" => "其他应用"}
    get admins_app_path(@a, tab: "profile")
    assert_select "[role=alert]", /AppID 与当前应用不一致/
    assert_select "#signature", count: 0
    @b.app_authorization.update!(refresh_token: nil)
    get admins_app_path(@b, tab: "profile")
    assert_select "a", text: "查看平台授权"
    assert_select "#signature", count: 0
    patch admins_app_profile_path(@b), params: {field: "signature", signature: "未经授权"}
    assert_match(/授权/, flash[:alert])
    [App.create!(provider: "wechat", app_type: "official_account", appid: "wxOffice"),
     App.create!(provider: "douyin", appid: "ttHospital")].each do |app|
      get admins_app_path(app)
      assert_select ".nav-link", text: "账号资料", count: 0
      patch admins_app_profile_path(app), params: {field: "signature"}
      assert_response :not_found
    end
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "profile_#{role}", role: role)
      get admins_app_path(@a, tab: "profile", nickname: "医院门诊")
      assert_response :forbidden
      patch admins_app_profile_path(@a), params: {field: "head_image"}
      assert_response :forbidden
    end
  end

  private

  def revision(app, field)
    get admins_app_path(app, tab: "profile")
    assert_response :success
    css_select("#wechat-profile-#{field} [name=revision]").first["value"]
  end
end

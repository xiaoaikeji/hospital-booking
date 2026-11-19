require "test_helper"
require_relative "../support/wechat_http_test"

class WechatTemplateCatalogTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "catalog_super", role: "super_admin")
    sign_in @admin
    Rails.cache.write("wechat/component/wxPlatform/token", "local")
  end
  teardown { remove_wechat_stubs }

  test "微信确认写入后丢弃旧库；拒绝写入可继续使用上次成功的快照" do
    catalog = WechatPlatform::CodeTemplates.new
    @stubs.get("/wxa/gettemplatelist") { response_for(template_list: [ {template_id: 9}, {template_id: 23} ]) }
    assert_equal [23, 9], catalog.refresh(:templates).pluck("template_id")
    @stubs.post("/wxa/addtotemplate") do |env|
      assert_equal({"draft_id" => 10, "template_type" => 1}, JSON.parse(env.body))
      response_for(errcode: 0)
    end
    post admins_code_templates_path, params: {draft_id: 10, template_type: "standard"}
    assert_redirected_to admins_code_templates_path
    assert_nil catalog.snapshot(:templates)
    assert_equal "success", Log.where(action: "wechat.template_add", actor_id: @admin.id).last.status

    catalog.refresh(:templates)
    @stubs.post("/wxa/deletetemplate") { response_for(errcode: 85014) }
    delete admins_code_template_path(23)
    assert_redirected_to admins_code_templates_path
    assert_match(/85014/, flash[:alert])
    assert_equal [23, 9], catalog.snapshot(:templates).pluck("template_id")
    assert_equal "failed", Log.where(action: "wechat.template_delete", actor_id: @admin.id).last.status

    @stubs.post("/wxa/deletetemplate") { response_for(errcode: 0) }
    delete admins_code_template_path(23)
    assert_redirected_to admins_code_templates_path
    assert_nil catalog.snapshot(:templates)
    assert_equal "success", Log.where(action: "wechat.template_delete", actor_id: @admin.id).last.status
  end

  test "空联系方式与不可读服务类目在提审弹窗分别提醒并允许继续" do
    app = App.create!(provider: "wechat", appid: "wxPreflight")
    auth = app.create_app_authorization!(refresh_token: "local")
    Rails.cache.write("apps/#{app.id}/channel_token", {value: "test-token", revision: auth.updated_at.to_f})
    release = app.mini_program_releases.create!(operator: @admin, version: "1.0", description: "门诊", template_id: "9", current_build: true, status: "uploaded")
    @stubs.post("/cgi-bin/component/getprivacysetting") { response_for(owner_setting: {contact_email: " ", notice_method: "专用通知方式"}) }
    @stubs.get("/cgi-bin/wxopen/getcategory") { raise Faraday::TimeoutError }
    get confirmation_admins_mini_program_release_path(release), params: {app_id: app.id, operation: "submit"}
    assert_response :success
    assert_select ".alert-warning", text: /缺少主体联系方式/
    assert_select ".alert-warning", text: /服务类目暂不可读/
    assert_select "button[type=submit]:not([disabled])", text: /确认提审/
  end
end

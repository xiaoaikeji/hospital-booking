require "test_helper"
require_relative "../support/wechat_http_test"

class WechatPrivacySettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "privacy_super", role: "super_admin")
    sign_in @admin
    @a, @b = %w[A B].map do |suffix|
      app = App.create!(provider: "wechat", appid: "wxPrivacy#{suffix}")
      auth = app.create_app_authorization!(refresh_token: "local")
      Rails.cache.write("apps/#{app.id}/channel_token", { value: "token-#{suffix}", revision: auth.updated_at.to_f })
      app
    end
    @live = { "privacy_list" => ["Location"], "setting_list" => [], "code_exist" => 1,
      "owner_setting" => { "contact_email" => "office@example.test", "notice_method" => "医院公告", "store_expire_timestamp" => 1890000000 } }
    @writes = []
    @stubs.post("/cgi-bin/component/getprivacysetting") { response_for(@live) }
    @stubs.post("/cgi-bin/component/setprivacysetting") do |env|
      values = JSON.parse(env.body)
      @writes << [Rack::Utils.parse_query(env.url.query)["access_token"], values]
      @live.merge!(values.slice("owner_setting", "setting_list"))
      raise Faraday::TimeoutError if @disconnect_after_write
      response_for(errcode: 0)
    end
  end
  teardown { remove_wechat_stubs }

  def form
    get edit_admins_app_privacy_setting_path(@a)
    assert_response :success
    { revision: css_select("#privacy_revision").first["value"],
      owner: { contact_email: "a@example.test", notice_method: "院内公告" },
      entries: {"0" => {key: "Location", purpose: "选择就近院区", enabled: "1"} } }
  end

  test "修改已授权 A 的开发版，保留微信其他设置；超时重发先读生效值，重复请求无写入" do
    input = form
    assert_select "input[value='office@example.test']"
    assert_select "#privacy-enabled-0[checked]", count: 0
    @disconnect_after_write = true
    patch admins_app_privacy_setting_path(@a), params: {privacy: input}
    assert_response :unprocessable_content
    assert_match(/核实/, flash[:alert])
    @disconnect_after_write = false
    patch admins_app_privacy_setting_path(@a), params: {privacy: input}
    assert_redirected_to admins_app_path(@a, tab: "privacy")
    assert_equal 1, @writes.size
    token, payload = @writes.first
    assert_equal "token-A", token
    assert_equal 2, payload["privacy_ver"]
    assert_equal 1890000000, payload.dig("owner_setting", "store_expire_timestamp")
    assert_equal [{"privacy_key" => "Location", "privacy_text" => "选择就近院区"}], payload["setting_list"]
    log = Log.find_by!(action: "wechat.privacy_update", status: "success", target_id: @a.id)
    assert_equal @admin.id, log.actor_id
    assert_no_match(/example|选择就近/, log.details.to_json)
    assert_empty Log.where(action: "wechat.privacy_update", target_id: @b.id)
  end

  test "微信已变化或用途缺失阻止写入，保留修改；运营、未授权、其他类型无写权限" do
    input = form
    @live["owner_setting"]["notice_method"] = "微信端已更改"
    patch admins_app_privacy_setting_path(@a), params: {privacy: input}
    assert_response :unprocessable_content
    assert_includes response.body, "微信指引已变更"
    assert_select "textarea", text: "选择就近院区"
    input = form
    input[:entries]["0"][:purpose] = ""
    patch admins_app_privacy_setting_path(@a), params: {privacy: input}
    assert_response :unprocessable_content
    assert_select "#privacy-purpose-0.is-invalid[aria-describedby='privacy-purpose-0-error']"
    assert_select "#privacy-purpose-0-error.invalid-feedback", "请填写已勾选声明项的实际用途"
    @a.app_authorization.update!(refresh_token: nil)
    patch admins_app_privacy_setting_path(@a), params: {privacy: input}
    assert_not response.successful?
    official = App.create!(provider: "wechat", appid: "wxPrivacyOa", app_type: "official_account")
    get edit_admins_app_privacy_setting_path(official)
    assert_response :not_found
    sign_in Admin.create!(username: "privacy_operator", role: "operator")
    patch admins_app_privacy_setting_path(@b), params: {privacy: input}
    assert_response :forbidden
    assert_empty @writes
  end
end

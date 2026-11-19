require "test_helper"
require_relative "../support/wechat_http_test"

class WechatDomainsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "domain_admin", role: "super_admin")
    sign_in @admin
    @target = App.create!(provider: "wechat", appid: "wxDomainA")
    auth = @target.create_app_authorization!(refresh_token: "test")
    Rails.cache.write("apps/#{@target.id}/channel_token", { value: "app-a", revision: auth.updated_at.to_f })
    @live = { "server" => { "requestdomain" => ["https://api.example.org"], "uploaddomain" => ["https://images.example.org"] },
      "business" => { "webviewdomain" => ["https://hospital.example.org"] } }
    @writes = []
    Wechat::MiniProgramDomainClient::PATHS.each do |kind, path|
      @stubs.post(path) do |env|
        assert_equal "app-a", env.params["access_token"]
        data = JSON.parse(env.body)
        if data.delete("action") == "set"
          @writes << kind
          @live[kind] = data
          raise Faraday::TimeoutError if @timeout
          response_for(errcode: 0)
        else
          response_for(@live.fetch(kind))
        end
      end
    end
  end

  teardown { remove_wechat_stubs }

  def revision(kind)
    get admins_app_path(@target, tab: "domains")
    assert_response :success
    css_select("##{kind}-revision").first["value"]
  end

  test "当前应用专属读写；空字段保留、显式清空、旧表单拦截且仅记录变更的类别" do
    rev = revision("server")
    patch admins_app_server_domain_path(@target), params: { domains: { requestdomain: "https://new.example.org:8443", uploaddomain: "" }, revision: rev }
    assert_redirected_to admins_app_path(@target, tab: "domains")
    assert_equal ["https://images.example.org"], @live.dig("server", "uploaddomain")
    assert_equal ["https://new.example.org:8443"], @live.dig("server", "requestdomain")
    assert_equal ["requestdomain"], Log.last.details["fields"]
    patch admins_app_server_domain_path(@target), params: { revision: rev, clear: ["requestdomain"] }
    assert_includes flash[:alert], "已变化"
    assert_equal ["server"], @writes
    patch admins_app_server_domain_path(@target), params: { revision: revision("server"), clear: ["requestdomain"], domains: { requestdomain: "" } }
    assert_empty @live.dig("server", "requestdomain")
    assert_equal ["https://hospital.example.org"], @live.dig("business", "webviewdomain")
  end

  test "业务域名验证协议端口；超时重新核对，远端已生效时再次保存不会重复发请求" do
    rev = revision("business")
    %w[http://hospital.example.org https://hospital.example.org:443 https://hospital.example.org/path].each do |bad|
      patch admins_app_business_domain_path(@target), params: { revision: rev, domains: { webviewdomain: bad } }
      assert flash[:alert].present?
    end
    assert_empty @writes
    @timeout = true
    input = { revision: rev, domains: { webviewdomain: "https://booking.example.org" } }
    patch admins_app_business_domain_path(@target), params: input
    assert_includes flash[:alert], "核实"
    assert_equal "failed", Log.last.status
    patch admins_app_business_domain_path(@target), params: input
    assert_includes flash[:alert], "已变化"
    patch admins_app_business_domain_path(@target), params: input.merge(revision: revision("business"))
    assert_equal ["business"], @writes
  end

  test "读取失败仅影响对应表单；无授权、其他应用类型以及运营和客服不能写微信" do
    @live["server"] = { "errcode" => 48001 }
    get admins_app_path(@target, tab: "domains")
    assert_response :success
    assert_select "form[action=?]", admins_app_server_domain_path(@target), count: 0
    assert_select "form[action=?]", admins_app_business_domain_path(@target), count: 1
    b = App.create!(provider: "wechat", appid: "wxDomainB")
    patch admins_app_server_domain_path(b)
    assert_includes flash[:alert], "平台授权"
    official = App.create!(provider: "wechat", appid: "wxOfficial", app_type: "official_account")
    patch admins_app_business_domain_path(official)
    assert_response :not_found
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "domain_#{role}", role: role)
      patch admins_app_business_domain_path(@target)
      assert_response :forbidden
    end
    assert_empty @writes
  end
end

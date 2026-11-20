require "test_helper"
require_relative "../support/wechat_http_test"

class WechatAuthorizerRotationTest < ActiveSupport::TestCase
  include WechatHttpTest
  self.use_transactional_tests = false

  setup do
    install_wechat_stubs
    suffix = SecureRandom.hex(6)
    @admin = Admin.create!(username: "rotation_#{suffix}", role: "super_admin")
    @a, @b = %w[a b].map do |letter|
      app = App.create!(provider: "wechat", appid: "wx#{suffix}#{letter}")
      app.create_app_authorization!(refresh_token: "refresh-#{letter}")
      app
    end
    Rails.cache.write("wechat/component/wxPlatform/token", "component")
    @calls = []
    current = "refresh-a"
    @stubs.post("/cgi-bin/component/api_authorizer_token") do |env|
      data = JSON.parse(env.body)
      given = data.fetch("authorizer_refresh_token")
      if given != current || data.fetch("authorizer_appid") != @a.appid
        response_for(errcode: 61023)
      else
        @calls << given
        current = "next-#{@calls.size}"
        response_for(authorizer_access_token: "access-#{@calls.size}", authorizer_refresh_token: current, expires_in: 7200)
      end
    end
    @stubs.post("/cgi-bin/component/getprivacysetting") { response_for(owner_setting: {"notice_method" => "公告"}) }
    @stubs.post("/wxa/modify_domain") { response_for(requestdomain: []) }
    @stubs.post("/wxa/setwebviewdomain") { response_for(webviewdomain: []) }
  end

  teardown do
    Log.where(actor_type: "Admin", actor_id: @admin.id).delete_all
    AppAuthorization.where(app: [@a, @b]).delete_all
    App.where(id: [@a.id, @b.id]).delete_all
    @admin.destroy!
    remove_wechat_stubs
  end

  test "无效邮箱和过期域名表单各自失败后仍可用新的授权凭据再次刷新" do
    assert_match(/邮箱/, invalid_privacy.message)
    Rails.cache.delete("apps/#{@a.id}/channel_token")
    assert_match(/变化/, stale_domains.message)
    Rails.cache.delete("apps/#{@a.id}/channel_token")
    assert_equal "access-3", WechatPlatform::AuthorizerToken.fetch(@a)
    assert_equal %w[refresh-a next-1 next-2], @calls
    assert_equal "next-3", @a.app_authorization.reload.refresh_token
    assert_equal "refresh-b", @b.app_authorization.reload.refresh_token
  end

  test "同一应用两份表单同时刷新凭据，失败后下一次仍可读取，另一应用独立" do
    ready, start = Queue.new, Queue.new
    threads = %i[invalid_privacy stale_domains].map do |method|
      Thread.new do
        App.connection_pool.with_connection do
          ready << true
          start.pop
          public_send(method).message
        end
      end
    end
    threads.size.times { ready.pop }
    threads.size.times { start << true }
    messages = threads.map(&:value)
    assert_match(/邮箱/, messages.first)
    assert_match(/变化/, messages.last)
    assert_equal ["refresh-a"], @calls
    Rails.cache.delete("apps/#{@a.id}/channel_token")
    assert_equal "access-2", WechatPlatform::AuthorizerToken.fetch(@a)
    assert_equal "next-2", @a.app_authorization.reload.refresh_token
    assert_equal "refresh-b", @b.app_authorization.reload.refresh_token
  end

  def invalid_privacy
    assert_raises(WechatPlatform::Error) do
      WechatPlatform::PrivacySettings.new(App.find(@a.id)).apply!(
        {"owner" => {"contact_email" => "broken"}}, actor: @admin, request: nil)
    end
  end

  def stale_domains
    assert_raises(WechatPlatform::Error) do
      WechatPlatform::AppDomains.new(App.find(@a.id)).replace!("server", texts: {}, clear: [], expected: "stale")
    end
  end
end

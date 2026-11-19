require "test_helper"
require_relative "../support/wechat_http_test"

class WechatSubmissionVisibilityTest < ActiveSupport::TestCase
  include WechatHttpTest
  self.use_transactional_tests = false

  test "微信收到提审时另一数据库连接已能读到审核中并可人工停用" do
    install_wechat_stubs
    suffix = SecureRandom.hex(6)
    admin = Admin.create!(username: "visibility_#{suffix}", role: "super_admin")
    app = App.create!(provider: "wechat", appid: "wx#{suffix}", status: "active", appsecret: "demo")
    auth = app.create_app_authorization!(refresh_token: "demo-refresh")
    Rails.cache.write("apps/#{app.id}/channel_token", { value: "demo-token", revision: auth.updated_at.to_f })
    release = app.mini_program_releases.create!(template_id: "88", operator: admin, version: "1.1", description: "门诊",
      status: "uploaded", current_build: true)
    @stubs.get("/cgi-bin/wxopen/getcategory") { response_for(categories: []) }
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: "demo-token") }
    @stubs.post("/wxa/getversioninfo") { response_for(errcode: 0) }
    @stubs.get("/wxa/get_latest_auditstatus") { response_for(errcode: 85058) }
    @stubs.post("/wxa/submit_audit") do
      observed = Thread.new do
        App.connection_pool.with_connection do
          App.transaction do
            App.connection.execute("SET LOCAL lock_timeout = '3s'")
            row = App.find(app.id)
            status = row.status
            row.update!(status: "disabled")
            status
          end
        end
      end.value
      assert_equal "auditing", observed
      response_for(errcode: 61039)
    end
    service = WechatPlatform::MiniProgramReleaseService.new(app, actor: admin)
    assert_raises(WechatPlatform::Error) { service.submit!(release, description: "核实", auto_publish: false, expected_round: 0) }
    assert_equal "disabled", app.reload.status
  ensure
    if app
      MiniProgramAudit.where(app_id: app.id).delete_all
      MiniProgramRelease.where(app_id: app.id).delete_all
      AppAuthorization.where(app_id: app.id).delete_all
      App.where(id: app.id).delete_all
    end
    if admin
      Log.where(actor_type: "Admin", actor_id: admin.id).delete_all
      Admin.where(id: admin.id).delete_all
    end
    remove_wechat_stubs
  end
end

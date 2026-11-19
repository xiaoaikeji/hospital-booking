require "test_helper"
require_relative "../support/wechat_http_test"

class WechatReleasesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest
  teardown { remove_wechat_stubs }
  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "release_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxA wxB].map do |appid|
      App.create!(provider: "wechat", appid: appid, appsecret: "demo-#{appid}", status: "active")
    end
    auth = @a.create_app_authorization!(refresh_token: "demo-refresh", original_id: "gh_A")
    Rails.cache.write("apps/#{@a.id}/channel_token", { value: "demo-authorizer", revision: auth.updated_at.to_f })
    @service = WechatPlatform::MiniProgramReleaseService.new(@a, actor: @admin)
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: "demo-direct") }
  end

  def upload
    @uploads = 0
    @stubs.post("/wxa/commit") do |env|
      @uploads += 1
      body = JSON.parse(env.body)
      assert_equal @a.appid, JSON.parse(body.fetch("ext_json")).fetch("extAppid")
      response_for(errcode: 0)
    end
    @service.upload!(template_id: "10", version: "1.1", description: "门诊")
  end

  def prepare_submit
    @a.update!(verified_digest: AppConfiguration.new(@a).digest(@a.appsecret))
    @online = {}
    @stubs.post("/wxa/getversioninfo") { response_for(errcode: 0, exp_info: { exp_version: "1.1", exp_desc: "门诊" }, release_info: @online) }
    @stubs.get("/wxa/get_latest_auditstatus") { response_for(@latest_remote_id ? { errcode: 0, auditid: @latest_remote_id } : { errcode: 85058 }) }
  end

  def submit(release, auto: false)
    @service.submit!(release, description: "审核说明", auto_publish: auto, expected_round: @a.mini_program_audits.maximum(:id))
  end

  test "明确拒收恢复原状态，检测等待后重提沿用体验版" do
    release = upload
    prepare_submit
    @stubs.post("/wxa/submit_audit") { response_for(errcode: 61039) }
    assert_raises(WechatPlatform::Error) { submit(release) }
    assert_equal "active", @a.reload.status
    assert_equal "not_accepted", @a.mini_program_audits.last.status
    @stubs.post("/wxa/submit_audit") do
      %w[1.0 1.1].each do |version|
        get api_app_configuration_path("wechat", @a.appid), params: { version: version }
        assert_equal "auditing", response.parsed_body["status"]
        assert_not response.parsed_body.key?("appsecret")
      end
      get api_app_configuration_path("wechat", @b.appid)
      assert_equal "active", response.parsed_body["status"]
      response_for(errcode: 0, auditid: 123)
    end
    assert_equal "123", submit(release).audit_id
    assert_equal 1, @uploads
  end

  test "提审超时保留审核中并禁止重复发送" do
    release = upload
    prepare_submit
    @stubs.post("/wxa/submit_audit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { submit(release) }
    assert_equal "submit_unknown", @a.mini_program_audits.last.status
    assert_equal "auditing", @a.reload.status
    assert_raises(WechatPlatform::Error) { submit(release) }
    assert_equal 1, @a.mini_program_audits.count
  end

  def accepted_round(release, id, auto: false)
    @stubs.post("/wxa/submit_audit") do
      @latest_remote_id = id
      response_for(errcode: 0, auditid: id)
    end
    submit(release, auto: auto)
  end

  test "迟到结果只更新旧轮，延后保留审核中，删除版本后仍追踪并保留人工停用" do
    release = upload
    prepare_submit
    first = accepted_round(release, 701)
    second = accepted_round(release, 702)
    @stubs.post("/wxa/get_auditstatus") do |env|
      id = JSON.parse(env.body).fetch("auditid")
      response_for(errcode: 0, status: id == 701 ? 1 : 4)
    end
    @service.sync!(first)
    assert_equal "rejected", first.reload.status
    assert_equal "auditing", @a.reload.status
    @service.sync!(second)
    assert_equal "delayed", second.reload.status
    get admins_app_path(@a)
    assert_response :success
    assert_includes response.body, "审核延后"
    patch admins_app_path(@a), params: { app: { status: "disabled", revision: AppConfiguration.new(@a).revision } }
    @service.retire!(release, delete: false)
    @service.retire!(release, delete: true)
    assert_nil second.reload.mini_program_release_id
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    @service.sync!(second)
    assert_equal "passed", second.reload.status
    get api_app_configuration_path("wechat", @a.appid)
    assert_response :forbidden
    assert_equal "disabled", response.parsed_body["status"]
    get api_app_configuration_path("wechat", @b.appid)
    assert_response :success
  end

  test "超时后先核实新版单号，逐单复查，已受理无需重复发送" do
    release = upload
    prepare_submit
    @stubs.post("/wxa/submit_audit") { raise Faraday::ConnectionFailed }
    assert_raises(WechatPlatform::Error) { submit(release) }
    audit = @a.mini_program_audits.last
    @latest_remote_id = 801
    assert_raises(WechatPlatform::Error) { @service.sync!(audit) }
    assert_raises(WechatPlatform::Error) { @service.resolve!(audit, outcome: "accepted", confirmed_id: "999") }
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 2) }
    @service.resolve!(audit, outcome: "accepted", confirmed_id: "801")
    assert_equal "801", audit.reload.audit_id
    assert_equal "pending", audit.status
  end

  test "微信已受理后本地成功审计写入失败，保留意图及远端单号" do
    release = upload
    prepare_submit
    reject_log = -> { throw(:abort) if action == "wechat.submit" && status == "success" }
    Log.set_callback(:create, :before, reject_log)
    @stubs.post("/wxa/submit_audit") { response_for(errcode: 0, auditid: 850) }
    assert_raises(WechatPlatform::Error) { submit(release) }
    assert_equal "submit_unknown", @a.mini_program_audits.last.status
    assert_equal "auditing", @a.reload.status
    failure = Log.find_by!(action: "wechat.submit", status: "failed")
    assert_includes failure.details["remote_result"], "850"
  ensure
    Log.skip_callback(:create, :before, reject_log) if reject_log
  end

  test "撤回仅作用于远端最新轮次，配额错误可见，成功后恢复正常" do
    release = upload
    prepare_submit
    audit = accepted_round(release, 901)
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 2) }
    @stubs.get("/wxa/undocodeaudit") { response_for(errcode: 87013) }
    assert_raises(WechatPlatform::Error) { @service.withdraw!(audit) }
    assert_equal "pending", audit.reload.status
    @stubs.get("/wxa/undocodeaudit") { response_for(errcode: 0) }
    @service.withdraw!(audit)
    assert_equal "withdrawn", audit.reload.status
    assert_equal "active", @a.reload.status
  end

  test "重复签名回调、补查与重复发布任务仅产生一次远端发布" do
    release = upload
    prepare_submit
    audit = accepted_round(release, 951, auto: true)
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    count = 0
    @stubs.post("/wxa/release") do
      count += 1
      response_for(errcode: 0)
    end
    path = "/api/wechat/component/apps/wxA/messages"
    xml = "<xml><ToUserName>gh_A</ToUserName><MsgType>event</MsgType><Event>weapp_audit_success</Event></xml>"
    Sidekiq.testing!(:fake) do
      signed_push(path, xml.sub("gh_A", "gh_B"))
      assert_response :forbidden
      2.times do
        signed_push(path, xml)
        assert_response :success
      end
      WechatPlatform::AuditPollWorker.new.perform
      WechatPlatform::AuditEventWorker.drain
      assert_equal "passed", audit.reload.status
      assert_equal "active", @a.reload.status
      WechatPlatform::AuditPollWorker.new.perform
      WechatPlatform::AutoPublishWorker.drain
      WechatPlatform::AutoPublishWorker.new.perform(audit.id)
    end
    assert_equal 1, count
    assert_equal "published", audit.reload.publication
    assert_not Log.exists?(action: "wechat.publish")
  end

  test "发布受理后断线，重跑先查线上版本，只核实不重发" do
    release = upload
    prepare_submit
    audit = accepted_round(release, 971)
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    @service.sync!(audit)
    count = 0
    @stubs.post("/wxa/release") do
      count += 1
      raise Faraday::TimeoutError
    end
    assert_raises(WechatPlatform::Error) { @service.publish!(audit) }
    assert_equal "publish_unknown", audit.reload.publication
    assert_raises(WechatPlatform::Error) { @service.publish!(audit) }
    @online = { release_version: "1.1", release_time: Time.current.to_i }
    @service.publish!(audit)
    assert_equal "published", audit.reload.publication
    assert_equal 1, count
  end

  test "后台从模板选择、上传、提审到手动发布，按父应用隔离每个管理接口" do
    Rails.cache.write("wechat/component/wxPlatform/token", "demo-token")
    @stubs.get("/wxa/gettemplatelist") { response_for(template_list: [ { template_id: 88, user_version: "1.1" } ]) }
    get new_admins_app_release_path(@a)
    assert_response :success
    assert_select "option[value='88']"
    @stubs.post("/wxa/commit") { response_for(errcode: 0) }
    post admins_app_releases_path(@a), params: { release: { template_id: "88", version: "1.1", description: "门诊" } }
    release = @a.mini_program_releases.sole
    @stubs.get("/wxa/get_qrcode") { [ 200, { "Content-Type" => "image/png" }, "\x89PNGdemo".b ] }
    get trial_admins_app_release_path(@a, release)
    assert_response :success
    assert_equal "image/png", response.media_type
    prepare_submit
    @stubs.post("/wxa/submit_audit") { response_for(errcode: 0, auditid: 51) }
    post submit_admins_app_release_path(@a, release), params: { expected_round: "0", description: "提审" }
    assert_redirected_to admins_app_path(@a)
    audit = @a.mini_program_audits.sole
    @latest_remote_id = 51
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    patch sync_admins_app_audit_path(@a, audit)
    assert_equal "passed", audit.reload.status
    @stubs.post("/wxa/release") { response_for(errcode: 0) }
    post publish_admins_app_audit_path(@a, audit)
    assert_equal "published", audit.reload.publication
    post publish_admins_app_audit_path(@b, audit)
    assert_response :not_found
  end

  test "上传断线使旧体验版失效，核实后复用新上传，不重置代码检测" do
    first = upload
    @stubs.post("/wxa/commit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { @service.upload!(template_id: "11", version: "1.1", description: "门诊") }
    assert_not first.reload.current_build?
    assert_equal "active", @a.reload.status
    latest = @a.mini_program_releases.last
    prepare_submit
    @service.verify_upload!(latest)
    assert latest.reload.current_build?
    assert_equal "uploaded", latest.status
  end

  test "上传只改变 A 的体验版，A、B 的运行状态不变" do
    release = upload
    assert release.current_build?
    assert_equal "uploaded", release.status
    assert_equal %w[active active], [ @a.reload.status, @b.reload.status ]
    assert Log.exists?(action: "wechat.upload", actor_id: @admin.id)
    delete admins_app_path(@a)
    assert App.exists?(@a.id)
  end
end

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
    @stubs.get("/cgi-bin/wxopen/getcategory") { response_for(categories: []) }
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
    @latest_fields = {}
    @stubs.get("/wxa/get_latest_auditstatus") do
      if @latest_remote_id
        response_for({ errcode: 0, auditid: @latest_remote_id, user_version: "1.1",
          submit_audit_time: @a.mini_program_audits.last.created_at.to_i }.merge(@latest_fields))
      else
        response_for(errcode: 85058)
      end
    end
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

  # 部署前可产生同一应用多轮重叠的数据，继续回放旧数据的恢复分支。
  def historical_overlap(build, previous, id: nil)
    @latest_remote_id = id if id
    @a.mini_program_audits.create!(operator: @admin, mini_program_release: build, version: build.version,
      description: "历史提审", audit_id: id&.to_s, status: id ? "pending" : "submit_unknown",
      previous_audit_id: previous.audit_id, previous_audit_pending: true, previous_status: "auditing",
      submission_finished_at: Time.current)
  end

  test "迟到结果只更新旧轮，延后保留审核中，删除版本后仍追踪并保留人工停用" do
    release = upload
    prepare_submit
    first = accepted_round(release, 701)
    release = upload
    second = historical_overlap(release, first, id: 702)
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
    assert_includes @service.sync!(audit), "候选审核单 801"
    assert_equal "submit_unknown", audit.reload.status
    assert_nil audit.audit_id
    assert_raises(WechatPlatform::Error) { @service.resolve!(audit, outcome: "accepted", confirmed_id: "999") }
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 2) }
    @service.resolve!(audit, outcome: "accepted", confirmed_id: "801")
    assert_equal "801", audit.reload.audit_id
    assert_equal "pending", audit.status
  end

  test "超时认领和发布都拒绝版本或提交时间不属于本轮的微信单号" do
    release = upload
    prepare_submit
    @stubs.post("/wxa/submit_audit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { submit(release, auto: true) }
    audit = @a.mini_program_audits.sole
    @latest_remote_id = 801
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    publishes = 0
    @stubs.post("/wxa/release") do
      publishes += 1
      response_for(errcode: 0)
    end

    Sidekiq.testing!(:fake) do
      conflicts = [ { user_version: "2.0" }, { submit_audit_time: audit.created_at.to_i - 60 },
        { submit_audit_time: audit.created_at.to_i + 3600 }, { user_version: nil }, { submit_audit_time: nil } ]
      conflicts.each do |fields|
        @latest_fields = fields
        assert_raises(WechatPlatform::Error) { @service.resolve!(audit, outcome: "accepted", confirmed_id: "801") }
        assert_equal "submit_unknown", audit.reload.status
        assert_nil audit.audit_id
      end
      assert_empty WechatPlatform::AutoPublishWorker.jobs.select { |job| job["args"] == [ audit.id ] }
      @latest_fields = {}
      @service.resolve!(audit, outcome: "accepted", confirmed_id: "801")
      assert_equal "passed", audit.reload.status
      @latest_fields = { user_version: "2.0" }
      assert_raises(WechatPlatform::Error) { @service.publish!(audit, automatic: true) }
      assert_raises(WechatPlatform::Error) { WechatPlatform::AutoPublishWorker.new.perform(audit.id) }
      assert_equal "unpublished", audit.reload.publication
      assert_equal 0, publishes
    end
  end

  test "后轮超时未受理时按前轮的当前结果恢复应用状态" do
    release = upload
    prepare_submit
    first = accepted_round(release, 701)
    release = upload
    second = historical_overlap(release, first)
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    @service.sync!(first)
    assert_equal "auditing", @a.reload.status
    @service.resolve!(second, outcome: "not_accepted", confirmed_id: "")
    assert_empty @a.mini_program_audits.pending
    get api_app_configuration_path("wechat", @a.appid)
    assert_equal "active", response.parsed_body["status"]
    assert_equal "active", @b.reload.status
  end

  test "未受理不能提前结束前轮审核，也不能恢复已人工停用的应用" do
    release = upload
    prepare_submit
    first = accepted_round(release, 705)
    release = upload
    historical_overlap(release, first)
    @service.resolve!(@a.mini_program_audits.last, outcome: "not_accepted", confirmed_id: "")
    assert_equal "pending", first.reload.status
    assert_equal "auditing", @a.reload.status

    historical_overlap(release, first)
    @a.update!(status: "disabled")
    @stubs.post("/wxa/get_auditstatus") { response_for(errcode: 0, status: 0) }
    @service.sync!(first)
    @service.resolve!(@a.mini_program_audits.last, outcome: "not_accepted", confirmed_id: "")
    get api_app_configuration_path("wechat", @a.appid)
    assert_response :forbidden
    assert_equal "disabled", response.parsed_body["status"]
  end

  test "补查旧拒审反馈不改变手动设置的审核中" do
    release = upload
    prepare_submit
    first = accepted_round(release, 706)
    feedback = {}
    @stubs.post("/wxa/get_auditstatus") { response_for({ status: 1 }.merge(feedback)) }
    @service.sync!(first)
    assert_equal "active", @a.reload.status
    @a.update!(status: "auditing")
    @stubs.post("/wxa/submit_audit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { submit(release) }
    feedback[:reason] = "补充审核意见"
    @service.sync!(first)
    @service.resolve!(@a.mini_program_audits.last, outcome: "not_accepted", confirmed_id: "")
    assert_equal "auditing", @a.reload.status
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

  test "拒审反馈随单号保存、显示并可补查，迟到和重复通知不影响新轮次" do
    release = upload
    prepare_submit
    rejected = accepted_round(release, 881)
    pending = historical_overlap(upload, rejected, id: 882)
    feedback = { reason: "请补充门诊预约的测试说明", ScreenShot: "media-one|media-two" }
    @stubs.post("/wxa/get_auditstatus") do |env|
      id = JSON.parse(env.body).fetch("auditid")
      response_for(id == 881 ? { auditid: id, status: 1 }.merge(feedback) : { auditid: id, status: 2 })
    end
    Sidekiq.testing!(:fake) do
      xml = "<xml><ToUserName>gh_A</ToUserName><MsgType>event</MsgType><Event>weapp_audit_fail</Event></xml>"
      2.times { signed_push("/api/wechat/component/apps/wxA/messages", xml) }
      WechatPlatform::AuditEventWorker.drain
    end
    get admins_app_path(@a)
    assert_includes response.body, "请补充门诊预约的测试说明"
    assert_equal %w[media-one media-two], rejected.reload.rejection_screenshots
    assert_nil pending.reload.rejection_reason
    assert_equal "auditing", @a.reload.status
    feedback = {}
    @service.sync!(rejected)
    assert_equal "请补充门诊预约的测试说明", rejected.reload.rejection_reason
    assert_equal %w[media-one media-two], rejected.rejection_screenshots
    rejected.update!(rejection_reason: nil, rejection_screenshots: [])
    feedback = { reason: "请上传新版说明", screenshot: "new-a|new-b" }
    patch sync_admins_app_audit_path(@a, rejected)
    get admins_app_path(@a)
    assert_includes response.body, "请上传新版说明"
    assert_includes response.body, "new-b"
    assert_not_includes Log.pluck(:details).to_json, "new-b"
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

  test "核实未上传需微信仍为旧体验版，缺少版本信息不能恢复上传按钮" do
    first = upload
    @stubs.post("/wxa/commit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { @service.upload!(template_id: "11", version: "1.2", description: "更新") }
    unknown = @a.mini_program_releases.last
    @stubs.post("/wxa/getversioninfo") { response_for(errcode: 0) }
    assert_raises(WechatPlatform::Error) { @service.verify_upload!(unknown, not_uploaded: true) }
    assert_equal "upload_unknown", unknown.reload.status
    @stubs.post("/wxa/getversioninfo") { response_for(exp_info: { exp_version: first.version, exp_desc: first.description }) }
    @service.verify_upload!(unknown, not_uploaded: true)
    assert_equal "upload_failed", unknown.reload.status
    assert first.reload.current_build?
  end

  test "过审任务可补排且幂等，系统另记一次发布时间和结果" do
    build = upload
    prepare_submit
    audit = accepted_round(build, 981, auto: true)
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: 981, status: 0) }
    publishes = 0
    @stubs.post("/wxa/release") { publishes += 1; response_for(errcode: 0) }
    Sidekiq.testing!(:fake) do
      @service.sync!(audit)
      2.times { post resume_auto_admins_app_audit_path(@a, audit) }
      WechatPlatform::AutoPublishWorker.drain
    end
    assert_equal 1, publishes
    assert_predicate audit.reload.published_at, :present?
    event = Log.find_by!(action: "wechat.auto_publish", source: "system", target_type: "App", target_id: @a.id)
    assert_equal audit.id, event.details["round_id"]
    assert_not_includes Log.operations_visible_to(@admin), event
  end

  test "旧版本被拒后恢复原上传参数，61039 后再次提审不重置检测" do
    old = upload
    prepare_submit
    rejected = accepted_round(old, 982)
    @stubs.post("/wxa/get_auditstatus") { response_for(status: 1, reason: "请补充审核说明") }
    @service.sync!(rejected)
    @service.upload!(template_id: "11", template_type: "standard", version: "1.2", description: "新体验版")
    @stubs.post("/wxa/getversioninfo") { response_for(exp_info: { exp_version: "1.2", exp_desc: "新体验版" }) }
    @stubs.post("/wxa/submit_audit") { response_for(errcode: 61039) }
    assert_raises(WechatPlatform::MiniProgramReleaseService::SubmissionRejected) { submit(old) }
    restored = @a.mini_program_releases.last
    assert_equal old.id, restored.restored_for_id
    assert_equal old.id, restored.source_release_id
    assert_not WechatPlatform::ReleaseActions.new(@a, release: restored).submit?
    assert_raises(WechatPlatform::Error) { submit(restored) }
    assert_equal old.slice(*MiniProgramRelease::SNAPSHOT_FIELDS), restored.slice(*MiniProgramRelease::SNAPSHOT_FIELDS)
    assert_predicate restored, :current_build?
    assert_equal 3, @uploads
    @stubs.post("/wxa/getversioninfo") { response_for(exp_info: { exp_version: "1.1", exp_desc: "门诊" }) }
    accepted_round(old, 983)
    assert_equal 3, @uploads
    assert_equal 3, old.mini_program_audits.count
    assert_equal "auditing", @a.reload.status
    assert_equal "active", @b.reload.status
  end

  test "超时恢复旧体验版先人工核实，明确失败才允许重传且旧表单不能重复发" do
    old = upload
    prepare_submit
    @service.upload!(template_id: "11", version: "1.2", description: "新版")
    @stubs.post("/wxa/commit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { submit(old) }
    uncertain = @a.mini_program_releases.last
    assert_equal [old.id, "upload_unknown"], [uncertain.source_release_id, uncertain.status]
    assert_not WechatPlatform::ReleaseActions.new(@a, release: old).submit?
    assert_predicate WechatPlatform::ReleaseActions.new(@a, release: uncertain), :verify_upload?
    assert_empty old.mini_program_audits
    assert_raises(WechatPlatform::Error) { @service.retire!(uncertain, delete: true) }
    assert_raises(WechatPlatform::Error) { @service.retire!(old, delete: true) }
    assert_raises(WechatPlatform::Error) { submit(old) }
    @stubs.post("/wxa/getversioninfo") { response_for(exp_info: { exp_version: "1.2", exp_desc: "新版" }) }
    @service.verify_upload!(uncertain, not_uploaded: true)
    assert_equal "upload_failed", uncertain.reload.status
    assert_predicate uncertain.previous_build.reload, :current_build?
    @stubs.post("/wxa/commit") { response_for(errcode: 0) }
    assert_difference -> { MiniProgramRelease.count } do
      post retry_upload_admins_app_release_path(@a, uncertain)
    end
    assert_equal old.id, @a.mini_program_releases.last.restored_for_id
    assert_raises(WechatPlatform::Error) { @service.retry_upload!(uncertain) }
  end

  test "使用平台授权提审且无需直连凭据，取消授权后可将本轮改为手动" do
    build = upload
    prepare_submit
    @a.update!(appsecret: nil, verified_digest: nil)
    audit = accepted_round(build, 984, auto: true)
    @a.app_authorization.update!(refresh_token: nil)
    patch mode_admins_app_audit_path(@a, audit), params: { expected_mode: "1", auto_publish: "0" }
    assert_not_predicate audit.reload, :auto_publish?
    @service.publish!(audit, automatic: true)
    assert_equal "unpublished", audit.reload.publication
  end

  test "带单号的通知只有核对本轮状态和时间后才能补充延后原因" do
    build = upload
    prepare_submit
    audit = accepted_round(build, 985)
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: 985, status: 4) }
    event = {"type" => "weapp_audit_delay", "time" => audit.created_at.to_i, "audit_id" => "985", "reason" => "节假日延后"}
    @service.sync!(audit, event: event.merge("audit_id" => "987"))
    assert_nil audit.reload.delay_reason
    @service.sync!(audit, event: event.merge("time" => audit.created_at.to_i - 1))
    assert_nil audit.reload.delay_reason
    @service.sync!(audit, event: event)
    assert_equal "节假日延后", audit.reload.delay_reason
    assert_equal "auditing", @a.reload.status
    @service.retire!(build, delete: true)
    assert_nil audit.reload.mini_program_release_id
    assert_not audit.auto_publish?
  end

  test "撤回超时先查原单再恢复本轮或确认已撤回" do
    build = upload
    prepare_submit
    audit = accepted_round(build, 988)
    remote_status = 4
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: 988, status: remote_status, reason: "排队中") }
    @stubs.get("/wxa/undocodeaudit") { raise Faraday::TimeoutError }
    assert_raises(WechatPlatform::Error) { @service.withdraw!(audit) }
    assert_equal "withdraw_unknown", audit.reload.status
    assert_raises(WechatPlatform::Error) { @service.retire!(build, delete: true) }
    @service.sync!(audit)
    assert_equal "withdraw_unknown", audit.reload.status
    @service.resolve!(audit, outcome: "not_withdrawn", confirmed_id: nil)
    assert_equal "delayed", audit.reload.status
    assert_equal "排队中", audit.delay_reason
    assert_raises(WechatPlatform::Error) { @service.withdraw!(audit) }
    remote_status = 3
    @service.sync!(audit)
    assert_equal "withdrawn", audit.reload.status
    assert_equal "active", @a.reload.status
  end

  test "核实未发布后才能重试，重试前先确认远端尚未上线" do
    build = upload
    prepare_submit
    audit = accepted_round(build, 989)
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: 989, status: 0) }
    @service.sync!(audit)
    attempts = 0
    @stubs.post("/wxa/release") do
      attempts += 1
      raise Faraday::TimeoutError if attempts == 1
      response_for(errcode: 0)
    end
    assert_raises(WechatPlatform::Error) { @service.publish!(audit) }
    assert_equal "publish_unknown", audit.reload.publication
    assert_raises(WechatPlatform::Error) { @service.publish!(audit) }
    assert_equal 1, attempts
    @service.resolve!(audit, outcome: "not_published", confirmed_id: nil)
    assert_equal "failed", audit.reload.publication
    @online = { release_version: build.version, release_desc: "发布已生效", release_time: Time.current.to_i }
    @service.publish!(audit)
    assert_equal "published", audit.reload.publication
    assert_equal 1, attempts
  end

  test "1.1 在审允许准备 1.2，阻止同应用提审直到撤回，删除原记录不解除限制" do
    first = upload
    prepare_submit
    audit = accepted_round(first, 986)
    newer = @service.upload!(template_id: "11", version: "1.2", description: "新版")
    other = @b.mini_program_releases.create!(operator: @admin, status: "uploaded", current_build: true, template_id: "11", version: "1.2", description: "体检")
    @b.create_app_authorization!(refresh_token: "test-b")
    assert_predicate WechatPlatform::ReleaseActions.new(@b, release: other), :submit?

    %w[pending delayed].each do |status|
      audit.update!(status: status)
      policy = WechatPlatform::ReleaseActions.new(@a, release: newer)
      assert_equal audit, policy.blocked_by_review
      assert_not policy.submit?
      assert_no_difference -> { MiniProgramAudit.count } do
        post submit_admins_app_release_path(@a, newer), params: { expected_round: audit.id }, as: :json
        assert_response :unprocessable_content
        assert_includes response.parsed_body["error"], "1.1 正在审核"
      end
    end

    @service.retire!(first, delete: true)
    assert_nil audit.reload.mini_program_release_id
    assert_raises(WechatPlatform::Error) { submit(newer) }
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: 986, status: 3) }
    @service.sync!(audit)
    @stubs.post("/wxa/getversioninfo") { response_for(exp_info: { exp_version: newer.version, exp_desc: newer.description }) }
    assert_equal "987", accepted_round(newer, 987).audit_id
    assert_equal "active", @b.reload.status
    assert_empty @b.mini_program_audits
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

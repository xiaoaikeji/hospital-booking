require "test_helper"
require_relative "../support/wechat_http_test"

class WechatManagementTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "management_super", role: "super_admin")
    sign_in @admin
    Rails.cache.write("wechat/component/wxPlatform/token", "test-component")
    @a, @b = %w[wxManageA wxManageB].map do |appid|
      app = App.create!(provider: "wechat", appid: appid, status: "active")
      auth = app.create_app_authorization!(refresh_token: "local-refresh", original_id: "gh_#{appid}")
      Rails.cache.write("apps/#{app.id}/channel_token", {value: "local-#{appid}", revision: auth.updated_at.to_f})
      app
    end
  end
  teardown { remove_wechat_stubs }

  def release(app = @a, version: "1.1")
    app.mini_program_releases.create!(operator: @admin, version: version, description: "门诊", template_id: "7", current_build: true, status: "uploaded")
  end

  def pending(build, auto:)
    build.app.mini_program_audits.create!(operator: @admin, mini_program_release: build, version: build.version,
      audit_id: "801", status: "pending", auto_publish: auto, description: "初审", previous_status: "active",
      submission_finished_at: Time.current)
  end

  def approved_by_wechat(round)
    @publishes = 0
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: round.audit_id, status: 0) }
    @stubs.get("/wxa/get_latest_auditstatus") do
      response_for(auditid: round.audit_id, user_version: round.version, submit_audit_time: round.created_at.to_i)
    end
    @stubs.post("/wxa/getversioninfo") { response_for(release_info: {}) }
    @stubs.post("/wxa/release") { @publishes += 1; response_for(errcode: 0) }
  end

  test "在审改手动后旧任务不发布，过审才出现手动入口，旧弹窗失效且 B 独立" do
    build = release
    round = pending(build, auto: true)
    other = pending(release(@b), auto: true)
    approved_by_wechat(round)
    get admins_mini_program_releases_path(app_id: @a.id)
    assert_select "button", text: "修改发布方式"
    assert_select "button", text: /^发布$/, count: 0
    assert_select "button", text: "提交审核", count: 0
    post publish_admins_app_audit_path(@a, round)
    assert_equal 0, @publishes
    patch mode_admins_app_audit_path(@a, round), params: { expected_mode: "1", auto_publish: "0" }
    assert_not round.reload.auto_publish?
    log = Log.find_by!(action: "wechat.publication_mode", actor_id: @admin.id)
    assert_equal [true, false, round.id], log.details.values_at("before", "after", "round_id")
    Sidekiq.testing!(:fake) do
      patch sync_admins_app_audit_path(@a, round)
      WechatPlatform::AutoPublishWorker.new.perform(round.id)
    end
    assert_equal 0, @publishes
    assert round.reload.approved_at
    get admins_mini_program_release_path(build)
    assert_select "button", text: /^发布$/, count: 1
    patch mode_admins_app_audit_path(@a, round), params: { expected_mode: "0", auto_publish: "1" }, as: :json
    assert_response :unprocessable_content
    assert_match(/刷新/, response.parsed_body.fetch("error"))
    post publish_admins_app_audit_path(@b, round)
    assert_response :not_found
    assert other.reload.auto_publish?
    assert_equal "pending", other.status
    assert_equal "active", @b.reload.status
  end

  test "在审改自动后重复回调任务只发布一次，等待期间拒绝手工发布" do
    build = release
    round = pending(build, auto: false)
    approved_by_wechat(round)
    patch mode_admins_app_audit_path(@a, round), params: { expected_mode: "0", auto_publish: "1" }
    Sidekiq.testing!(:fake) do
      xml = "<xml><ToUserName>gh_wxManageA</ToUserName><MsgType>event</MsgType><Event>weapp_audit_success</Event></xml>"
      2.times do
        signed_push("/api/wechat/component/apps/wxManageA/messages", xml)
        assert_response :success
      end
      WechatPlatform::AuditEventWorker.drain
      get admins_mini_program_releases_path
      assert_select "td", text: "等待自动发布"
      assert_select "button", text: /^发布$/, count: 0
      post publish_admins_app_audit_path(@a, round)
      assert_equal 0, @publishes
      2.times { WechatPlatform::AutoPublishWorker.new.perform(round.id) }
    end
    assert_equal 1, @publishes
    assert_equal "published", round.reload.publication
  end

  test "旧数据中后一尝试已核实未受理，列表与详情均保留前一有效轮次的发布动作" do
    build = release
    accepted = pending(build, auto: false)
    accepted.update!(status: "passed")
    failed = build.mini_program_audits.create!(app: @a, operator: @admin, description: "未受理", previous_status: "active",
      version: build.version, status: "not_accepted")
    [admins_mini_program_releases_path(status: "passed"), admins_mini_program_release_path(build)].each do |url|
      get url
      assert_response :success
      assert_select "form[action=?]", publish_admins_app_audit_path(@a, accepted), count: 1
      assert_select "form[action=?]", publish_admins_app_audit_path(@a, failed), count: 0
      assert_select "button", text: "提交审核", count: 0
    end
  end

  test "平台模板读取失败保留快照，标准模板冻结实际参数，正常读取时拒绝不存在的模板" do
    @stubs.get("/wxa/gettemplatedraftlist") { response_for(draft_list: []) }
    @stubs.get("/wxa/gettemplatelist") { response_for(template_list: [{ template_id: 7, template_type: 1, user_version: "2.0", user_desc: "门诊" }]) }
    sent = []
    @stubs.post("/wxa/commit") { |env| sent << JSON.parse(env.body); response_for(errcode: 0) }
    post admins_app_releases_path(@a), params: { release: { template_id: "7", version: "2.0", description: "门诊", template_type: "standard" } }
    assert_equal({"extAppid" => @a.appid}, JSON.parse(sent.sole.fetch("ext_json")))
    assert_equal({"extAppid" => @a.appid}, @a.mini_program_releases.sole.ext_config)
    post admins_app_releases_path(@a), params: { release: { template_id: "999", version: "3.0" } }, as: :json
    assert_response :unprocessable_content
    assert_equal 1, sent.size
    @stubs.get("/wxa/gettemplatelist") { raise Faraday::TimeoutError }
    get admins_code_templates_path(fresh: 1)
    assert_includes response.body, "上次成功读取"
    assert_includes response.body, "2.0"
    assert_includes response.body, "已使用 1 次"
  end

  test "预检提示隐私声明，提审只发送通过的服务类目，明确拒收后原弹窗可重试" do
    build = release
    @a.update!(appsecret: "sample", status: "auditing")
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: "local") }
    @stubs.post("/cgi-bin/component/getprivacysetting") { response_for(privacy_list: ["Location"], setting_list: []) }
    @stubs.get("/cgi-bin/wxopen/getcategory") do
      response_for(categories: [
        {first: 1, second: 2, first_name: "医疗", second_name: "预约", audit_status: 3},
        {first: 1, second: 3, second_name: "未通过", audit_status: 2}
      ])
    end
    get confirmation_admins_mini_program_release_path(build), params: {app_id: @a.id, operation: "submit"}
    assert_response :success
    assert_includes response.body, "Location"
    assert_includes response.body, "医疗 / 预约"
    assert_not_includes response.body, "未通过"
    assert_select "input[type=checkbox][checked]"
    @stubs.post("/wxa/getversioninfo") { response_for(errcode: 0) }
    @stubs.get("/wxa/get_latest_auditstatus") { response_for(errcode: 85058) }
    calls = 0
    @stubs.post("/wxa/submit_audit") do |env|
      body = JSON.parse(env.body)
      assert_equal "本轮说明", body["version_desc"]
      assert_equal [2], body.fetch("item_list").pluck("second_id")
      calls += 1
      response_for(calls == 1 ? {errcode: 61039} : {auditid: 707})
    end
    args = {description: "本轮说明", expected_round: "0", auto_publish: "1"}
    post submit_admins_app_release_path(@a, build), params: args, as: :json
    assert_response :unprocessable_content
    revision = response.parsed_body.fetch("expected_round")
    assert_not response.parsed_body.fetch("reconcile")
    post submit_admins_app_release_path(@a, build), params: args.merge(expected_round: revision), as: :json
    assert_response :success
    assert_equal %w[not_accepted pending], build.mini_program_audits.order(:id).pluck(:status)
    assert_equal "active", @b.reload.status
  end

  test "代码阶段按业务名称筛选，待核实仍能定位，返回保留筛选且不能向别的应用上传" do
    build = release
    round = pending(build, auto: true)
    round.update!(status: "submit_unknown", audit_id: nil)
    release(@b, version: "2.1")
    get admins_mini_program_releases_path(app_id: @a.id, q: "1.1", status: "pending")
    assert_response :success
    labels = css_select("nav[aria-label='发布状态'] a").map { |link| link.text.strip }
    assert_equal %w[全部 进行中 上传中 已上传 上传失败 审核中 审核延后 审核拒绝 审核通过 已撤回 已发布 发布失败 已关闭], labels
    assert_select "tbody tr", count: 1
    assert_select "td.release-status .badge", text: "审核中"
    assert_select "td.release-result", text: /待确认微信是否受理/
    assert_select "#release-upload", count: 0
    assert_select "#upload-requirements a", text: "核实上次操作"
    assert_select "button", text: "核实本轮结果"
    detail_url = css_select("td.release-operations a").first["href"]
    get detail_url
    assert_response :success
    return_link = css_select("a").find { |link| link.text.include?("返回代码列表") }
    query = Rack::Utils.parse_nested_query(URI(return_link["href"]).query)
    assert_equal({ "app_id" => @a.id.to_s, "page" => "1", "q" => "1.1", "status" => "pending" }, query)
    get admins_mini_program_releases_path(status: "uploaded", app_id: @b.id)
    assert_select "td.release-status .badge", text: "已上传"
    assert_select "tbody tr", count: 1
  end

  test "截图仅代理本应用本轮素材，失败可重试，角色及应用类型受服务端限制" do
    build = release
    round = pending(build, auto: false)
    round.update!(status: "rejected", rejection_screenshots: ["local-media"])
    path = screenshot_admins_app_audit_path(@a, round, index: 0)
    calls = 0
    @stubs.post("/cgi-bin/material/get_material") do |env|
      assert_equal "local-media", JSON.parse(env.body)["media_id"]
      calls += 1
      if calls == 1
        response_for(errcode: 40007)
      else
        [200, {"Content-Type" => "image/png"}, "\x89PNG\r\n\x1a\n".b + "local-image"]
      end
    end
    get path, params: {media_id: "other"}
    assert_response :service_unavailable
    assert_includes response.body, "素材已失效"
    2.times { get path; assert_response :success; assert_equal "image/png", response.media_type }
    get screenshot_admins_app_audit_path(@b, round, index: 0)
    assert_response :not_found
    assert_equal 2, calls
    official = App.create!(provider: "wechat", app_type: "official_account", appid: "official")
    get new_admins_app_release_path(official)
    assert_response :not_found
    get admins_app_path(official)
    assert_select "h2", text: "平台授权"
    assert_select "h2", text: "代码发布", count: 0
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "management_#{role}", role: role)
      [path, admins_code_templates_path, admins_mini_program_release_path(build)].each { |url| get url; assert_response :forbidden }
      post admins_code_templates_path, params: {draft_id: 1, template_type: "standard"}
      assert_response :forbidden
      patch mode_admins_app_audit_path(@a, round), params: {expected_mode: "0", auto_publish: "1"}
      assert_response :forbidden
    end
  end
end

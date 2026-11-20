require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class WechatResultsAndViolationsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "result_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wx1111111111111111 wx2222222222222222].map do |appid|
      app = App.create!(provider: "wechat", appid: appid)
      auth = app.create_app_authorization!(refresh_token: "local-token", original_id: "gh_#{appid}")
      Rails.cache.write("apps/#{app.id}/channel_token", { value: appid, revision: auth.updated_at.to_f })
      app
    end
    @key = "demo-only-notification-key"
    @sent = []
    @stubs.post("https://qyapi.weixin.qq.com/cgi-bin/webhook/send") do |env|
      assert_equal @key, env.params.fetch("key")
      @sent << JSON.parse(env.body).fetch("text").fetch("content")
      raise Faraday::TimeoutError if @timeout
      response_for(errcode: @errcode || 0)
    end
    @setting = Setting.create!(key: "wechat_notifications")
    @setting.write_value("webhook_key", @key)
    @setting.write_value("pull_violations", true)
    @setting.write_value("kinds", WechatPlatform::NotificationSettings::LABELS.keys)
    @setting.save!
    @violations = Hash.new { |hash, key| hash[key] = [] }
    @appeals = []
    @stubs.post("/wxa/getillegalrecords") do |env|
      query = JSON.parse(env.body)
      assert_equal 7.days.to_i, query.fetch("end_time") - query.fetch("start_time")
      token = env.params.fetch("access_token")
      token == @expired_token ? response_for(errcode: 42001) : response_for(records: @violations[token])
    end
    @stubs.post("/wxa/getappealrecords") do |env|
      assert JSON.parse(env.body).fetch("illegal_record_id").is_a?(String)
      response_for(records: @appeals)
    end
  end
  teardown { remove_wechat_stubs }

  test "首次历史不通知，同院同号隔离，新增与申诉变化只发送一次" do
    row = {illegal_record_id: "rec_22", create_time: 1.day.ago.to_i, illegal_reason: "请核对服务类目", rule_url: "javascript:alert(1)"}
    @violations[@a.appid] << row
    @violations[@b.appid] << row
    @appeals << {appeal_record_id: 42, appeal_status: 1, appeal_time: 1.day.ago.to_i}
    worker = WechatPlatform::IllegalRecordWorker.new
    worker.perform
    assert_equal [1, 1], [@a.wechat_violations.count, @b.wechat_violations.count]
    assert_equal 2, WechatAppeal.count
    assert_empty WechatNotificationEvent.all
    @appeals.first[:appeal_status] = 3
    2.times { worker.perform(@a.id) }
    assert_equal 1, @b.wechat_violations.sole.appeals.sole.status
    assert_equal 3, @a.wechat_violations.sole.appeals.sole.status
    @violations[@a.appid] << row.merge(illegal_record_id: "rec_33")
    2.times { WechatPlatform::IllegalRecords.sync(@a) }
    assert_equal %w[appeal_3 violation], WechatNotificationEvent.order(:id).pluck(:kind)
    2.times { WechatNotificationEvent.find_each { |e| WechatPlatform::NotificationWorker.new.perform(e.id) } }
    assert_equal 2, @sent.size
    assert @sent.all? { |s| s.include?(@a.appid) && !s.include?(@b.appid) }
    get admins_illegal_records_path(app_id: @a.id)
    assert_response :success
    assert_select "a[href^='javascript:']", count: 0
    assert_select ".modal h3", /申诉记录/
    assert_includes response.body, "已通知"
    assert_not_includes response.body, @key
  end

  test "A 的令牌过期保留已有记录，同次任务仍同步 B" do
    row = { illegal_record_id: "local_17", create_time: 2.days.ago.to_i }
    @violations[@a.appid] << row
    WechatPlatform::IllegalRecords.sync(@a)
    previous_sync = @a.reload.violations_synced_at
    @violations[@b.appid] << row
    @expired_token = @a.appid
    WechatPlatform::IllegalRecordWorker.new.perform
    assert_equal previous_sync, @a.reload.violations_synced_at
    assert_equal ["local_17"], @a.wechat_violations.pluck(:record_number)
    assert_nil Rails.cache.read("apps/#{@a.id}/channel_token")
    assert_equal @b.appid, Rails.cache.read("apps/#{@b.id}/channel_token")[:value]
    assert_equal ["local_17"], @b.wechat_violations.pluck(:record_number)
    assert_predicate @b.reload.violations_synced_at, :present?
    assert_empty WechatNotificationEvent.all
  end

  test "审核与发布只通知已确认的变化，同轮重放与回滚不产生第二次消息" do
    a = @a.mini_program_audits.create!(operator: @admin, audit_id: "3001", status: "pending", version: "1.1", previous_status: "active", description: "示例")
    assert_no_difference("WechatNotificationEvent.count") do
      MiniProgramAudit.transaction { a.update!(status: "passed"); raise ActiveRecord::Rollback }
    end
    a.reload.update!(status: "delayed", delay_reason: "需要更多时间")
    a.update!(status: "passed")
    a.update!(publication: "publish_unknown")
    assert_equal %w[delayed passed], WechatNotificationEvent.order(:id).pluck(:kind)
    a.update!(publication: "failed", error_code: 85051)
    a.update!(publication: "publish_unknown")
    a.update!(publication: "failed")
    a.update!(publication: "published")
    assert_equal %w[delayed passed failed published], WechatNotificationEvent.order(:id).pluck(:kind)
    WechatNotificationEvent.find_each { |e| WechatPlatform::NotificationWorker.new.perform(e.id) }
    assert_equal 4, @sent.size
    assert_includes @sent.last, "版本：1.1"
    assert_includes @sent.last, "3001"
    assert_empty @b.wechat_notification_events
    newer = @a.mini_program_audits.create!(operator: @admin, audit_id: "3002", status: "pending", version: "1.1", previous_status: "active", description: "重提")
    newer.update!(status: "rejected", rejection_reason: "补充<br>说明")
    assert_equal 1, @a.wechat_notification_events.where(kind: "rejected").count
  end

  test "重复审核回调和自动发布任务只发布一次，按本轮留下两条通知" do
    @a.update!(status: "auditing")
    build = @a.mini_program_releases.create!(operator: @admin, template_id: "10", version: "1.2", description: "演示", current_build: true, status: "uploaded")
    round = build.mini_program_audits.create!(app: @a, operator: @admin, version: build.version, description: "提审", status: "pending",
      auto_publish: true, audit_id: "3200", previous_status: "active", submission_finished_at: Time.current)
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: round.audit_id, status: 0) }
    @stubs.get("/wxa/get_latest_auditstatus") { response_for(auditid: round.audit_id, user_version: round.version, submit_audit_time: round.created_at.to_i) }
    @stubs.post("/wxa/getversioninfo") { response_for(release_info: {}) }
    sends = 0
    @stubs.post("/wxa/release") { sends += 1; response_for(errcode: 0) }
    Sidekiq.testing!(:fake) do
      2.times { WechatPlatform::AuditEventWorker.new.perform(@a.id) }
      2.times { WechatPlatform::AutoPublishWorker.new.perform(round.id) }
      2.times { WechatNotificationEvent.find_each { |event| WechatPlatform::NotificationWorker.new.perform(event.id) } }
    end
    assert_equal 1, sends
    assert_equal "published", round.reload.publication
    assert_equal %w[passed published], @a.wechat_notification_events.order(:id).pluck(:kind)
    assert_equal 2, @sent.size
    assert_empty @b.wechat_notification_events
  end

  test "通知登记实际发生 SQL 错误，审核、违规和失败追踪仍落库" do
    Setting.create!(key: "notification")
    Setting.connection.execute("ALTER TABLE settings ADD CONSTRAINT test_notification_write CHECK (key <> 'notification') NOT VALID")
    @a.update!(status: "auditing", violations_synced_at: 1.day.ago)
    audit = @a.mini_program_audits.create!(operator: @admin, audit_id: "3010", status: "pending", version: "1.1",
      previous_status: "active", description: "示例")
    @stubs.post("/wxa/get_auditstatus") { response_for(auditid: "3010", status: 0) }
    WechatPlatform::MiniProgramReleaseService.new(@a, actor: @admin).sync!(audit)
    assert_equal "passed", audit.reload.status
    assert_equal "active", @a.reload.status

    now = Time.current.change(usec: 0)
    @violations[@a.appid] << { illegal_record_id: "notice-sql-error", create_time: now.to_i, illegal_reason: "违规" }
    WechatPlatform::IllegalRecords.sync(@a, now: now)
    violation = @a.wechat_violations.find_by!(record_number: "notice-sql-error")
    assert_equal "违规", violation.reload.reason
    assert_equal now, @a.reload.violations_synced_at
    assert_empty WechatNotificationEvent.all
    failure_logs = Log.where(source: "system", action: "notification.registration_failed", status: "failed", target_type: "App", target_id: @a.id).order(:id)
    assert_equal ["audit:#{audit.id}:passed", "violation:#{violation.id}"], failure_logs.map { |log| log.details["event_reference"] }
    assert failure_logs.all? { |log| log.details["error"].start_with?("ActiveRecord::") }
  end

  test "企微超时或明确拒绝均不重发，关闭通知后不发送已排队消息" do
    %w[unknown failed skipped].each_with_index do |expected, index|
      @timeout = index.zero?
      @errcode = 93000 if expected == "failed"
      WechatPlatform::ResultNotifications.category(@a, "5", "8", "3", index.to_s)
      event = WechatNotificationEvent.last
      @setting.update!(settings: @setting.settings.except("kinds")) if expected == "skipped"
      2.times { WechatPlatform::NotificationWorker.new.perform(event.id) }
      assert_equal expected, event.reload.status
    end
    assert_equal 2, @sent.size
  end

  test "超管查看生效密钥，修改与回退记录字段名，旧表单与低权限写请求被拦住" do
    @previous_env["WECOM_WEBHOOK_KEY"] = ENV["WECOM_WEBHOOK_KEY"]
    ENV["WECOM_WEBHOOK_KEY"] = "local-deploy-fallback"
    edit = edit_admins_system_settings_wechat_notifications_path
    path = admins_system_settings_wechat_notifications_path
    get edit
    assert_response :success
    assert_select "input[value=?]", @key
    revision = css_select("input[name='notification_settings[revision]']").first["value"]
    input = { revision: revision, webhook_key: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=new-demo-key", kinds: ["passed"], pull_violations: "1" }
    patch path, params: { notification_settings: input.merge(webhook_key: "invalid!") }
    assert_response :unprocessable_content
    assert_select "#notification_settings_webhook_key.is-invalid[aria-describedby='webhook_key-error']"
    assert_select "#webhook_key-error.invalid-feedback", /有效的机器人 Key/
    patch path, params: { notification_settings: input }
    assert_redirected_to edit
    assert_not_includes @setting.reload.settings.to_s, "new-demo-key"
    assert_equal "new-demo-key", WechatPlatform::NotificationSettings.new.key
    patch path, params: { notification_settings: input.merge(clear_key: "1") }
    assert_response :unprocessable_content
    assert_equal "new-demo-key", WechatPlatform::NotificationSettings.new.key
    patch path, params: { notification_settings: { revision: WechatPlatform::NotificationSettings.new.revision, clear_key: "1" } }
    assert_redirected_to edit
    assert_nil @setting.reload.settings["webhook_key"]
    assert_equal ["passed"], @setting.settings["kinds"]
    assert_equal true, @setting.settings["pull_violations"]
    get edit
    assert_select "input[value=?]", "local-deploy-fallback"
    assert_includes response.body, "环境变量"
    assert_not_includes Log.where(action: "wechat.notification_settings").pluck(:details).to_s, "new-demo-key"
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(role: role, username: "result_#{role}")
      [edit, admins_wechat_notifications_path, admins_illegal_records_path].each { |url| get url; assert_response :forbidden }
      patch path, params: {notification_settings: input}
      assert_response :forbidden
    end
  end

  test "已验签申诉回调只查目标应用，停用同步、授权撤销或错收件方都不查" do
    path = api_wechat_component_messages_path(appid: @a.appid)
    xml = "<xml><ToUserName>gh_#{@a.appid}</ToUserName><MsgType>event</MsgType><Event>wxa_appeal_record</Event></xml>"
    Sidekiq.testing!(:fake) do
      jobs = WechatPlatform::IllegalRecordWorker.jobs
      assert_difference(-> { jobs.size }, 1) { signed_push(path, xml); assert_response :success }
      assert_equal [@a.id], jobs.last["args"]
      assert_no_difference(-> { jobs.size }) do
        signed_push(path, xml.sub(@a.appid, @b.appid))
        assert_response :forbidden
        @setting.update!(settings: @setting.settings.merge("pull_violations" => false))
        signed_push(path, xml)
        assert_response :success
        WechatPlatform::IllegalRecordWorker.new.perform
        assert_nil @a.reload.violations_synced_at
        @a.app_authorization.update!(refresh_token: nil)
        signed_push(path, xml)
        assert_response :forbidden
      end
    end
  end

  test "企微密文损坏仍可替换和清除，清除后回退到可用配置" do
    @previous_env["WECOM_WEBHOOK_KEY"] = ENV["WECOM_WEBHOOK_KEY"]
    ENV["WECOM_WEBHOOK_KEY"] = "audit-safe-fallback"
    edit = edit_admins_system_settings_wechat_notifications_path
    path = admins_system_settings_wechat_notifications_path
    corrupt = { "ciphertext" => "invalid-channels-ciphertext" }
    2.times do |index|
      @setting.reload
      @setting.update!(settings: @setting.settings.merge("webhook_key" => corrupt))
      get edit
      assert_response :success
      assert_predicate WechatPlatform::NotificationSettings.new, :key_unreadable?
      assert_select "span[title='系统配置（解密失败）']", "解密失败"
      assert_select "form#clear-notification-configuration-form"
      assert_not_includes response.body, corrupt["ciphertext"]
      revision = css_select("input[name='notification_settings[revision]']").first["value"]
      input = index.zero? ? { webhook_key: "audit-replacement-key", kinds: ["passed"] } : { clear_key: "1" }
      patch path, params: { notification_settings: input.merge(revision: revision) }
      assert_redirected_to edit
      assert_equal(index.zero? ? "audit-replacement-key" : "audit-safe-fallback", WechatPlatform::NotificationSettings.new.key)
    end
    logs = Log.where(action: "wechat.notification_settings").pluck(:details).to_json
    %w[audit-replacement-key audit-safe-fallback invalid-channels-ciphertext].each { |key| assert_not_includes logs, key }
  end

  test "旧企微 Key 被轮换后，普通改回和清除回退都在设置页拒绝" do
    @previous_env["WECOM_WEBHOOK_KEY"] = ENV["WECOM_WEBHOOK_KEY"]
    ENV["WECOM_WEBHOOK_KEY"] = @key
    path = admins_system_settings_wechat_notifications_path
    channel = Notifications::Channels::WecomGroup.target(@key)
    input = { kinds: ["passed"] }
    patch path, params: { notification_settings: input.merge(revision: WechatPlatform::NotificationSettings.new.revision,
      webhook_key: "audit-rotated-key", same_robot: "1") }
    assert_redirected_to edit_admins_system_settings_wechat_notifications_path
    assert_equal channel, Notifications::Channels::WecomGroup.target("audit-rotated-key")
    [{ webhook_key: @key }, { clear_key: "1" }].each do |change|
      patch path, params: { notification_settings: input.merge(change).merge(revision: WechatPlatform::NotificationSettings.new.revision) }
      assert_response :unprocessable_content
      assert_includes response.body, "生效的机器人 Key 已轮换"
      assert_equal "audit-rotated-key", WechatPlatform::NotificationSettings.new.key
    end
    ENV["WECOM_WEBHOOK_KEY"] = "audit-rotated-key"
    patch path, params: { notification_settings: input.merge(revision: WechatPlatform::NotificationSettings.new.revision,
      webhook_key: "audit-third-key", same_robot: "1") }
    assert_redirected_to edit_admins_system_settings_wechat_notifications_path
    assert_equal channel, Notifications::Channels::WecomGroup.target("audit-third-key")
    patch path, params: { notification_settings: { revision: WechatPlatform::NotificationSettings.new.revision, clear_key: "1" } }
    assert_response :unprocessable_content
    assert_includes response.body, "生效的机器人 Key 已轮换"
    assert_equal "audit-third-key", WechatPlatform::NotificationSettings.new.key
    logs = Log.where(action: "wechat.notification_settings").pluck(:details).to_json
    [@key, "audit-rotated-key", "audit-third-key"].each { |key| assert_not_includes logs, key }
  end
end

require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationRecoveryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @account = App.create!(provider: "wechat", appid: "wxRecovery")
    @admin = Admin.create!(username: "notification_recovery", role: "super_admin")
    sign_in @admin
    @target = Notifications::Channels::WecomGroup.target("local-test-recovery-group")
    @calls = []
    @keys = []
    @stubs.post("/cgi-bin/webhook/send") do |env|
      @calls << JSON.parse(env.body).dig("text", "content")
      @keys << env.params.fetch("key")
      @after_webhook&.call
      rejected = @reject_second && @calls.size == @reject_call_number
      response_for(errcode: rejected ? 93000 : 0, errmsg: rejected ? "invalid webhook url" : "ok")
    end
    @reject_call_number = 2
  end
  teardown { remove_wechat_stubs }

  def dispatch_review(target = @target, idempotency_key: "audit-3")
    Notifications.dispatch(event: "passed", subject: @account, target: target, idempotency_key: idempotency_key,
      messages: %w[第一条 第二条].map.with_index { |text, i| { id: "msg_#{i}", type: "text", content: { text: text } } })
  end

  test "原目标改显示名或 JSON 键顺序后重放，仍复用同一条记录" do
    original = dispatch_review
    renamed = @target.to_a.reverse.to_h.merge("label" => "新显示名")
    assert_no_difference("Notification.count") { assert_equal original, dispatch_review(renamed) }
    assert_equal @target, original.reload.payload["target"]
  end

  test "第一条发起请求时进程退出，恢复后第一条待核实、第二条继续发送，失败时只补选中条目" do
    @reject_second = true
    @reject_call_number = 1
    task = dispatch_review
    task.update!(status: "sending", last_attempt_at: 15.minutes.ago, attempt_count: 1, response_data: {
      messages: [ { message_id: "msg_0", status: "sending", stage: "request_started", attempt_count: 1 } ]
    })
    Sidekiq.testing!(:fake) do
      Notifications::DeliveryWorker.jobs.clear
      Notifications::DeliveryWorker.new.perform
      Notifications::DeliveryWorker.drain
    end
    assert_equal [ "第二条" ], @calls
    task.reload
    assert_predicate task, :uncertain?
    assert_equal "awaiting_verification", task.result_for("msg_0").fetch("stage")
    assert_equal "unknown", task.result_for("msg_0").fetch("provider_state")
    assert_equal [ "msg_1" ], task.retryable_ids
    assert task.response_data["finished_at"].present?
    get admins_notification_path(task)
    assert_response :success
    assert_select "dt", text: "目标"
    assert_includes response.body, "待核实"
    assert_equal [ "msg_1" ], css_select('input[name="message_ids[]"]').map { |input| input["value"] }

    @reject_second = false
    post retry_failed_admins_notification_path(task), params: { message_ids: [ "msg_1" ] }
    assert_redirected_to admins_notification_path(task)
    Notifications::DeliveryWorker.new.perform(task.id)
    assert_equal [ "第二条", "第二条" ], @calls
    assert_equal "sent", task.reload.result_for("msg_1").fetch("status")
    assert_equal "sending", task.result_for("msg_0").fetch("status")
    assert_empty task.retryable_ids
    get admins_notification_path(task)
    assert_select 'input[name="message_ids[]"]', count: 0

    Sidekiq.testing!(:fake) do
      Notifications::DeliveryWorker.jobs.clear
      Notifications::DeliveryWorker.new.perform
      assert_empty Notifications::DeliveryWorker.jobs
    end
  end

  test "排队后关闭该类通知，尚未发送的条目跳过，通用记录与原微信审核记录一致" do
    Sidekiq.testing!(:fake) do
      settings = Setting.create!(key: "wechat_notifications")
      settings.write_value("webhook_key", "local-test-recovery-group")
      settings.write_value("kinds", [ "passed" ])
      settings.save!
      WechatPlatform::ResultNotifications.record(@account, "passed", "round:11", { "版本" => "1.1" })
      event = @account.wechat_notification_events.sole
      task = Notification.find_by!(subject: event)
      settings.write_value("kinds", [])
      settings.save!
      Notifications::DeliveryWorker.new.perform(task.id)
      WechatPlatform::NotificationWorker.new.perform(event.id)
      assert_empty @calls
      assert_equal "skipped", event.reload.status
      assert_predicate task.reload, :disabled?
      assert_equal "已跳过", task.status_label
      assert_empty task.retryable_ids
      get admins_notification_path(task)
      assert_response :success
      assert_includes response.body, "已跳过"
      assert_includes response.body, "事件通知已关闭，未发送"
      assert_select 'input[name="message_ids[]"]', count: 0

      # When msg 1 was already sent/interrupted and the kind is disabled before msg 2, only unsent msg 2 is skipped.
      settings.write_value("kinds", [ "passed" ])
      settings.save!
      WechatPlatform::NotificationContents.new("passed").save!(
        [ { id: "first", type: "text", content: { text: "第一条 {version}" } },
          { id: "second", type: "text", content: { text: "第二条 {app_name}" } } ],
        revision: WechatPlatform::NotificationContents.new("passed").revision, actor: @admin
      )
      WechatPlatform::ResultNotifications.record(@account, "passed", "round:12", { "版本" => "1.2" })
      partial_event = @account.wechat_notification_events.find_by!(event_key: "round:12")
      partial_task = Notification.find_by!(subject: partial_event)
      partial_task.update!(status: "sending", last_attempt_at: 15.minutes.ago, attempt_count: 1, response_data: {
        messages: [ { message_id: "first", status: "sending", stage: "request_started", attempt_count: 1 } ]
      })
      settings.write_value("kinds", [])
      settings.save!
      Notifications::DeliveryWorker.new.perform(partial_task.id)
      assert_empty @calls
      assert_equal "awaiting_verification", partial_task.reload.result_for("first").fetch("stage")
      assert_equal "disabled", partial_task.result_for("second").fetch("stage")
      assert_equal "unknown", partial_event.reload.status
      assert_empty partial_task.retryable_ids
    end
  end

  test "发送第一条时关闭通知，保留首条回执并跳过还未发送的第二条" do
    settings = Setting.create!(key: "wechat_notifications")
    settings.write_value("webhook_key", "local-test-recovery-group")
    settings.write_value("kinds", [ "passed" ])
    settings.save!
    @after_webhook = lambda do
      settings.write_value("kinds", [])
      settings.save!
    end
    Sidekiq.testing!(:fake) do
      event = @account.wechat_notification_events.create!(kind: "passed", event_key: "mid-send", status: "pending", message: "审核通过")
      task = Notifications.dispatch(event: "passed", subject: event, target: @target, idempotency_key: event.event_key,
        messages: %w[第一条 第二条].map { |text| { id: text, type: "text", content: { text: text } } })
      Notifications::Delivery.run(task.id)

      assert_equal [ "第一条" ], @calls
      assert_equal "channel_accepted", task.reload.result_for("第一条")["stage"]
      assert_equal "disabled", task.result_for("第二条")["stage"]
      assert_equal "部分已跳过", task.status_label
      assert_equal "partially_skipped", event.reload.status
      assert_empty task.retryable_ids
    end
  end

  test "默认群从 A 换到 B 时旧任务仍发 A；A 群机器人轮换密钥后可用新密钥补发，且不能占用别的群" do
    settings = Setting.create!(key: "wechat_notifications")
    settings.write_value("webhook_key", "local-test-recovery-group")
    settings.write_value("kinds", [ "passed" ])
    settings.save!
    other = Notifications::Channels::WecomGroup.target("local-test-different-group")

    # 1. Attempting to rotate into another already-registered group must fail and keep A intact.
    patch admins_system_settings_wechat_notifications_path, params: { notification_settings: {
      revision: WechatPlatform::NotificationSettings.new.revision, same_robot: "1",
      webhook_key: "local-test-different-group", kinds: [ "passed" ]
    } }
    assert_response :unprocessable_content
    assert_includes response.body, "新 Key 已登记在其他通知群"
    assert_equal "local-test-recovery-group", WechatPlatform::NotificationSettings.new.key
    assert_equal @target, Notifications::Channels::WecomGroup.target("local-test-recovery-group")
    assert_equal other, Notifications::Channels::WecomGroup.target("local-test-different-group")
    log = Log.where(action: "wechat.notification_settings", status: "failed").sole
    assert_not_includes log.details.to_json, "local-test-different-group"

    # 2. Switching default group from A to B (without same_robot): old task still delivers to A.
    queued_for_a = dispatch_review(idempotency_key: "audit-group-switch")
    patch admins_system_settings_wechat_notifications_path, params: { notification_settings: {
      revision: WechatPlatform::NotificationSettings.new.revision, same_robot: "0",
      webhook_key: "local-test-group-b", kinds: [ "passed" ]
    } }
    assert_redirected_to edit_admins_system_settings_wechat_notifications_path
    Notifications::Delivery.run(queued_for_a.id)
    assert_equal [ "local-test-recovery-group" ] * 2, @keys

    # 3. Rotating group B's own robot key (with same_robot: "1"): failed message retries with B's new key.
    @calls.clear
    @keys.clear
    @reject_second = true
    @reject_call_number = 2
    b_target = Notifications::Channels::WecomGroup.target("local-test-group-b")
    b_task = dispatch_review(b_target, idempotency_key: "audit-group-b-rotate")
    Notifications::Delivery.run(b_task.id)
    assert_equal [ "msg_1" ], b_task.reload.retryable_ids
    patch admins_system_settings_wechat_notifications_path, params: { notification_settings: {
      revision: WechatPlatform::NotificationSettings.new.revision, same_robot: "1",
      webhook_key: "local-test-group-b-rotated", kinds: [ "passed" ]
    } }
    assert_redirected_to edit_admins_system_settings_wechat_notifications_path
    assert_equal b_target, Notifications::Channels::WecomGroup.target("local-test-group-b-rotated")
    @reject_second = false
    post retry_failed_admins_notification_path(b_task), params: { message_ids: [ "msg_1" ] }
    assert_redirected_to admins_notification_path(b_task)
    Notifications::Delivery.run(b_task.id)
    assert_equal %w[第一条 第二条 第二条], @calls
    assert_equal %w[local-test-group-b local-test-group-b local-test-group-b-rotated], @keys
    assert_equal "sent", b_task.reload.status
    assert_equal 93000, b_task.result_for("msg_1").fetch("history").sole.dig("response", "errcode")
    assert_not_includes Setting.find_by!(key: "notification").settings.to_json, "local-test-group-b-rotated"
  end

  test "真实拒审理由跨两条企微消息，轮换原机器人 Key 后只补第二条并同步历史状态" do
    Sidekiq.testing!(:fake) do
      @reject_second = true
      @reject_call_number = 2
      settings = Setting.create!(key: "wechat_notifications")
      settings.write_value("webhook_key", "local-test-recovery-group")
      settings.write_value("kinds", [ "rejected" ])
      settings.save!
      round = @account.mini_program_audits.create!(operator: @admin, audit_id: "123456",
        status: "pending", version: "1.2", description: "演示审核", previous_status: "active")
      round.update!(status: "rejected", rejection_reason: "请补正页面说明。" * 100)
      event = @account.wechat_notification_events.sole
      row = Notification.find_by!(subject: event)
      target = row.payload.fetch("target").deep_dup
      assert_equal 2, row.messages.size
      2.times { WechatPlatform::NotificationWorker.new.perform(event.id) }
      assert_equal [ 0, 93000 ], row.reload.messages.map { |message| row.result_for(message["id"]).dig("response", "errcode") }
      assert_equal event.message, @calls.join
      assert @calls.all? { |text| text.valid_encoding? && text.bytesize <= 2048 }
      assert_equal "failed", event.reload.status
      get admins_wechat_notifications_path(app_id: @account.id)
      assert_select ".modal-footer a[href=?]", admins_notification_path(row), "查看发送任务"
      get admins_notification_path(row)
      assert_response :success
      assert_includes response.body, "invalid webhook url"
      assert_includes response.body, "93000"
      assert_equal [ row.messages.last.fetch("id") ], css_select('input[name="message_ids[]"]').map { |input| input["value"] }
      patch admins_system_settings_wechat_notifications_path, params: { notification_settings: {
        revision: WechatPlatform::NotificationSettings.new.revision,
        webhook_key: "local-test-replacement-key", kinds: [ "rejected" ], same_robot: "1"
      } }
      assert_redirected_to edit_admins_system_settings_wechat_notifications_path
      assert_equal target, Notifications::Channels::WecomGroup.target("local-test-replacement-key", name: "微信审核结果企微群")
      @reject_second = false
      post retry_failed_admins_notification_path(row), params: { message_ids: [ row.messages.last.fetch("id") ] }
      assert_redirected_to admins_notification_path(row)
      2.times { Notifications::DeliveryWorker.new.perform(row.id) }
      assert_equal [ @calls.first, @calls.second, @calls.second ], @calls
      assert_equal %w[local-test-recovery-group local-test-recovery-group local-test-replacement-key], @keys
      assert_equal "sent", event.reload.status
      assert_equal 93000, row.reload.result_for(row.messages.last.fetch("id")).fetch("history").sole.dig("response", "errcode")
      assert_nil event.error_code
      assert_equal "sent", row.reload.status
      assert_equal target, row.payload.fetch("target")
      assert_equal @admin.id, Log.where(action: "notification.retry", target_id: row.id, target_type: "Notification").sole.actor_id
      assert_not_includes Setting.find_by!(key: "notification").settings.to_json, "local-test-replacement-key"
    end
  end

  test "自定义多条企微文案替换超长变量后顺序拆条，保留原编排顺序并逐条记录结果" do
    Sidekiq.testing!(:fake) do
      settings = Setting.create!(key: "wechat_notifications")
      settings.write_value("webhook_key", "local-test-recovery-group")
      settings.write_value("kinds", [ "rejected" ])
      settings.save!
      content = WechatPlatform::NotificationContents.new("rejected")
      content.save!(
        [
          { id: "intro", type: "text", content: { text: "{app_name} {version} {result}" } },
          { id: "detail", type: "text", content: { text: "拒审原因：{reason}" } },
          { id: "outro", type: "text", content: { text: "请按审核单 {audit_id} 修改后重提" } }
        ],
        revision: content.revision, actor: @admin
      )
      reason = "请补充门诊挂号页面说明。" * 100
      round = @account.mini_program_audits.create!(operator: @admin, audit_id: "654321",
        status: "pending", version: "2.0", description: "多条拆分", previous_status: "active")
      round.update!(status: "rejected", rejection_reason: reason)
      event = @account.wechat_notification_events.sole
      row = Notification.find_by!(subject: event)
      assert_operator row.messages.size, :>=, 4
      Notifications::DeliveryWorker.new.perform(row.id)
      assert_equal "#{@account.display_name} 2.0 审核未通过", @calls.first
      assert_equal "请按审核单 654321 修改后重提", @calls.last
      assert_equal "拒审原因：#{reason}", @calls[1..-2].join
      assert @calls.all? { |text| text.valid_encoding? && text.bytesize <= 2048 }
      assert_equal [ "sent" ] * row.messages.size, row.reload.messages.map { |m| row.result_for(m["id"]).fetch("status") }
      assert_equal "sent", event.reload.status
    end
  end
end

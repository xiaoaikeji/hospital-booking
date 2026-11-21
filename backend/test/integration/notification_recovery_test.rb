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

  def dispatch_activity(target = @target, idempotency_key: "audit-3")
    Notifications.dispatch(event: "activity_start", subject: @account, target: target, idempotency_key: idempotency_key,
      messages: %w[第一条 第二条].map.with_index { |text, i| { id: "msg_#{i}", type: "text", content: { text: text } } })
  end

  test "原目标改显示名或 JSON 键顺序后重放，仍复用同一条记录" do
    original = dispatch_activity
    renamed = @target.to_a.reverse.to_h.merge("label" => "新显示名")
    assert_no_difference("Notification.count") { assert_equal original, dispatch_activity(renamed) }
    assert_equal @target, original.reload.payload["target"]
  end

  test "第一条发起请求时进程退出，恢复后第一条待核实、第二条继续发送，失败时只补选中条目" do
    @reject_second = true
    @reject_call_number = 1
    task = dispatch_activity
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

  test "升级保留旧通知的发送策略和发送结果" do
    settings = Setting.create!(key: "wechat_notifications")
    settings.write_value("webhook_key", "local-test-recovery-group")
    settings.write_value("kinds", ["passed"])
    settings.save!
    Sidekiq.testing!(:fake) do
      event = WechatNotificationEvent.create!(app: @account, kind: "passed", event_key: "historical", message: "旧通知", status: "pending")
      task = Notifications.dispatch(event: "passed", subject: event, target: @target, idempotency_key: "historical",
        messages: [{id: "first", type: "text", content: {text: "既有发送快照"}}])
      settings.update!(settings: settings.settings.merge("kinds" => []))
      Notifications::DeliveryWorker.new.perform(task.id)
      assert_empty @calls
      assert_equal "skipped", event.reload.status
      assert_predicate task.reload, :disabled?
      get admins_notification_path(task)
      assert_response :success
      get admins_wechat_notifications_path
      assert_response :success
      assert_includes response.body, "审核通过"
    end
  end

  test "默认群从 A 换到 B 时旧任务仍发 A；A 群机器人轮换密钥后可用新密钥补发，且不能占用别的群" do
    settings = Setting.create!(key: "wechat_notifications")
    settings.write_value("webhook_key", "local-test-recovery-group")
    settings.write_value("kinds", [ "passed" ])
    settings.save!
    other = Notifications::Channels::WecomGroup.target("local-test-different-group")

    # 1. Attempting to rotate into another already-registered group must fail and keep A intact.
    patch admins_system_settings_wecom_notifications_path, params: { notification_settings: {
      revision: Notifications::WecomSettings.new.revision, same_robot: "1",
      webhook_key: "local-test-different-group"
    } }
    assert_response :unprocessable_content
    assert_includes response.body, "新 Key 已登记在其他通知群"
    assert_equal "local-test-recovery-group", Notifications::WecomSettings.new.key
    assert_equal @target, Notifications::Channels::WecomGroup.target("local-test-recovery-group")
    assert_equal other, Notifications::Channels::WecomGroup.target("local-test-different-group")
    log = Log.where(action: "wechat.notification_settings", status: "failed").sole
    assert_not_includes log.details.to_json, "local-test-different-group"

    # 2. Switching default group from A to B (without same_robot): old task still delivers to A.
    queued_for_a = dispatch_activity(idempotency_key: "audit-group-switch")
    patch admins_system_settings_wecom_notifications_path, params: { notification_settings: {
      revision: Notifications::WecomSettings.new.revision, same_robot: "0",
      webhook_key: "local-test-group-b"
    } }
    assert_redirected_to edit_admins_system_settings_wecom_notifications_path
    Notifications::Delivery.run(queued_for_a.id)
    assert_equal [ "local-test-recovery-group" ] * 2, @keys

    # 3. Rotating group B's own robot key (with same_robot: "1"): failed message retries with B's new key.
    @calls.clear
    @keys.clear
    @reject_second = true
    @reject_call_number = 2
    b_target = Notifications::Channels::WecomGroup.target("local-test-group-b")
    b_task = dispatch_activity(b_target, idempotency_key: "audit-group-b-rotate")
    Notifications::Delivery.run(b_task.id)
    assert_equal [ "msg_1" ], b_task.reload.retryable_ids
    patch admins_system_settings_wecom_notifications_path, params: { notification_settings: {
      revision: Notifications::WecomSettings.new.revision, same_robot: "1",
      webhook_key: "local-test-group-b-rotated"
    } }
    assert_redirected_to edit_admins_system_settings_wecom_notifications_path
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

end

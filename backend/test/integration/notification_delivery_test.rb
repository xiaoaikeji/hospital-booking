require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationDeliveryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "notification_admin", role: "super_admin")
    sign_in @admin
    @account = App.create!(provider: "wechat", appid: "wxnotifications001")
    setting = Setting.create!(key: "wechat_notifications")
    setting.write_value("webhook_key", "demo-notification-key")
    setting.write_value("kinds", [ "passed" ])
    setting.save!
    @sent = []
    @keys = []
    @stubs.post("/cgi-bin/webhook/send") do |env|
      @keys << env.params["key"]
      text = JSON.parse(env.body).dig("text", "content")
      @sent << text
      raise Faraday::TimeoutError if @timeout
      response_for(errcode: text == "第二条" && !@fixed ? 93000 : 0, errmsg: unsafe_receipt)
    end
  end
  teardown { remove_wechat_stubs }

  def task
    Notifications.dispatch(event: "passed", subject: @account,
      target: Notifications::Channels::WecomGroup.target("demo-notification-key"),
      messages: %w[第一条 第二条].each_with_index.map { |text, i| { id: "msg_#{i}", type: "text", content: { text: text } } },
      idempotency_key: "audit:1")
  end

  def unsafe_receipt
    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=demo-notification-key #{Base64.strict_encode64('demo-notification-key')}"
  end

  test "两条消息部分成功后仅补失败条目，固定快照并审计" do
    row = task
    Notifications::Delivery.run(row.id)
    assert_equal "failed", row.reload.status
    assert_equal %w[sent failed], row.results.map { |r| r["status"] }
    assert_includes row.error_message, "93000"
    assert_not_includes row.response_data.to_json, "demo-notification-key"
    assert_not_includes row.response_data.to_json, Base64.strict_encode64("demo-notification-key")
    # Older rows can still contain raw response text in the current attempt and its history.
    last = row.results.last
    legacy = last.merge("error_message" => unsafe_receipt)
    row.update!(response_data: row.response_data.merge("messages" => [ row.results.first, legacy.merge("history" => [ legacy ]) ]))
    get admins_notification_path(row)
    assert_response :success
    assert_includes response.body, "请核对群机器人设置"
    assert_not_includes response.body, "demo-notification-key"
    assert_not_includes response.body, Base64.strict_encode64("demo-notification-key")
    @fixed = true
    post retry_failed_admins_notification_path(row), params: { message_ids: [ "msg_1" ] }
    assert_redirected_to admins_notification_path(row)
    Notifications::Delivery.run(row.id)
    assert_equal "sent", row.reload.status
    assert_equal %w[第一条 第二条 第二条], @sent
    assert_equal [ 1, 2 ], row.messages.map { |m| row.result_for(m["id"])["attempt_count"] }
    assert_equal row.id, task.id
    assert_equal @admin.id, Log.where(action: "notification.retry").sole.actor_id
    assert_not_includes row.payload.to_json, "demo-notification-key"
  end

  test "超时与中断不能自动或人工重发，目标变更不能转发" do
    @timeout = true
    row = task
    2.times { Notifications::Delivery.run(row.id) }
    assert_equal "待核实", row.reload.status_label
    assert_equal 2, @sent.size
    post retry_failed_admins_notification_path(row), params: { message_ids: [ "msg_1" ] }
    assert_redirected_to admins_notification_path(row)
    assert_equal "sending", row.reload.status
    assert_equal "failed", Log.where(action: "notification.retry").last.status
    get admins_notification_path(row)
    assert_includes response.body, "待核实"
    assert_select "button", text: "仅补发这一条", count: 0
  end

  test "排队时选 A，默认改 B 后仍发 A，快照和渠道密钥保持隔离" do
    @fixed = true
    row = task
    setting = Setting.find_by!(key: "wechat_notifications")
    setting.write_value("webhook_key", "demo-group-b-key")
    setting.save!
    Notifications::Delivery.run(row.id)
    assert_equal [ "demo-notification-key", "demo-notification-key" ], @keys
    assert_equal "sent", row.reload.status
    assert_not_includes row.payload.to_json, "demo-group-b-key"
  end

  test "低权限拒绝直接查看和补发" do
    row = task
    sign_in Admin.create!(username: "notify_operator", role: "operator")
    get admins_notifications_path
    assert_response :forbidden
    get admins_notification_path(row)
    assert_response :forbidden
    post retry_failed_admins_notification_path(row), params: { message_ids: [ "msg_1" ] }
    assert_response :forbidden
  end
end

require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationContentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "content_admin", role: "super_admin")
    sign_in @admin
    @account = App.create!(provider: "wechat", appid: "wxContentA", nickname: "本次应用")
    @settings = Setting.create!(key: "wechat_notifications")
    @settings.write_value("webhook_key", "demo-content-group-a")
    @settings.write_value("kinds", WechatPlatform::NotificationSettings::LABELS.keys)
    @settings.save!
    @sent = []
    @stubs.post("/cgi-bin/webhook/send") do |env|
      text = JSON.parse(env.body).dig("text", "content")
      @sent << [ env.params["key"], text ]
      raise Faraday::TimeoutError if @timeout
      response_for(errcode: !@fixed && text.start_with?("原因：") ? 93000 : 0, errmsg: "invalid webhook url")
    end
  end
  teardown { remove_wechat_stubs }

  def content(kind = "rejected") = WechatPlatform::NotificationContents.new(kind)
  def input(texts) = texts.each_with_index.map { |text, i| { id: "text_#{i}", type: "text", content: { text: text } } }
  def save_content(texts, kind: "rejected")
    patch admins_system_settings_wecom_notification_content_path(event: kind), params: { notification_content: { revision: content(kind).revision, messages: input(texts) } }, as: :json
    assert_response :success
  end

  test "管理员可按事件保存文案，未知变量和并发编辑拒绝，恢复只影响本事件" do
    get edit_admins_system_settings_wecom_notification_content_path(event: "rejected")
    assert_response :success
    assert_select "[data-insert-variable=version]"
    assert_select "[data-insert-variable=partner_name]", count: 0
    old_revision = content.revision
    save_content([ "{app_name} {version} {result}", "原因：{reason}" ])
    stored = content.messages
    assert_equal "text_1", stored.last["id"]
    assert_equal "demo-content-group-a", WechatPlatform::NotificationSettings.new.key
    assert_not_includes Log.where(action: "notification.wecom_content").pluck(:details).to_json, "{app_name}"
    patch admins_system_settings_wecom_notification_content_path(event: "rejected"), params: { notification_content: { revision: old_revision, messages: input([ "别覆盖" ]) } }, as: :json
    assert_response :unprocessable_content
    assert_equal stored, content.messages
    patch admins_system_settings_wecom_notification_content_path(event: "rejected"), params: { notification_content: { revision: content.revision, messages: input([ "审核通知", "{balance}" ]) } }, as: :json
    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "{balance}"
    assert_equal "text", response.parsed_body["field"]
    assert_equal 1, response.parsed_body["message_index"]
    save_content([ "违规：{record_number}" ], kind: "violation")
    patch admins_system_settings_wecom_notification_content_path(event: "rejected"), params: { notification_content: { revision: content.revision, restore: "1" } }
    assert_redirected_to edit_admins_system_settings_wecom_notification_content_path(event: "rejected")
    assert_nil content.stored
    assert_equal "违规：{record_number}", content("violation").messages.first.dig("content", "text")
    get edit_admins_system_settings_wecom_notification_content_path(event: "violation")
    assert_select "[data-insert-variable=record_number]"
    assert_select "[data-insert-variable=version]", count: 0
  end

  test "真实触发替换变量后固定内容与 A 群，拒绝时仅补失败条目" do
    save_content([ "{app_name} {version} {result}", "原因：{reason}" ])
    Sidekiq.testing!(:fake) do
      WechatPlatform::ResultNotifications.record(@account, "rejected", "round:1", { "版本" => "2.0", "原因" => "需要<br>补充" })
      row = Notification.sole
      assert_equal [ "本次应用 2.0 审核未通过", "原因：需要\n补充" ], row.messages.map { |m| m.dig("content", "text") }
      save_content([ "新文案 {app_name}" ])
      @settings.write_value("webhook_key", "demo-content-group-b")
      @settings.save!
      @account.update!(nickname: "后来改名")
      WechatPlatform::ResultNotifications.deliver(WechatNotificationEvent.sole.id)
      assert_equal %w[sent failed], row.reload.messages.map { |m| row.result_for(m["id"])["status"] }
      @fixed = true
      post retry_failed_admins_notification_path(row), params: { message_ids: [ "text_1" ] }
      Notifications::Delivery.run(row.id)
      assert_equal [ "demo-content-group-a" ] * 3, @sent.map(&:first)
      assert_equal [ "本次应用 2.0 审核未通过", "原因：需要\n补充", "原因：需要\n补充" ], @sent.map(&:last)
      assert_equal "sent", row.reload.status
      assert_equal "sent", WechatNotificationEvent.sole.status
      assert_nil WechatNotificationEvent.sole.error_code
      assert_no_difference("Notification.count") { WechatPlatform::ResultNotifications.record(@account, "rejected", "round:1", { "版本" => "99", "原因" => "不同原因" }) }
      assert_equal 1, Log.where(action: "notification.retry", status: "success").count
    end
  end

  test "通用入口接收业务数据并固定替换结果，重复登记沿用原记录" do
    target = Notifications::Channels::WecomGroup.target("demo-content-group-a")
    rows = input([ "活动：{activity_name}，时间：{starts_at}" ])
    attributes = { event: "activity_start", subject: @account, target: target, messages: rows, idempotency_key: "activity:1" }
    Sidekiq.testing!(:fake) do
      row = Notifications.dispatch(**attributes, data: { activity_name: "第一场", starts_at: Time.zone.local(2026, 11, 28, 14) })
      assert_equal "活动：第一场，时间：2026-11-28 14:00:00", row.messages.first.dig("content", "text")
      duplicate = Notifications.dispatch(**attributes, data: { activity_name: "后来修改", starts_at: Time.current })
      assert_equal row.id, duplicate.id
      assert_equal row.messages, duplicate.messages
      assert_no_difference("Notification.count") do
        assert_raises(Notifications::Error) { Notifications.dispatch(**attributes.merge(idempotency_key: "missing"), data: { activity_name: "缺时间" }) }
      end
    end
  end

  test "可选空值省略整行，超时仍待核实；角色权限和模板用途隔离" do
    save_content([ "{result}\n原因：{reason}\n时间：{time}" ], kind: "rejected")
    @timeout = true
    Sidekiq.testing!(:fake) do
      WechatPlatform::ResultNotifications.record(@account, "rejected", "round:2", { "版本" => "1.0" })
      row = Notification.sole
      assert_not_includes row.messages.first.dig("content", "text"), "原因："
      WechatPlatform::ResultNotifications.deliver(WechatNotificationEvent.sole.id)
      assert_equal "待核实", row.reload.status_label
      assert_empty row.retryable_ids
    end
    assert_equal [ "activity_start" ], Notifications::EventCatalog.for_templates.keys
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "content_#{role}", role: role)
      get edit_admins_system_settings_wecom_notification_content_path
      assert_response :forbidden
      patch admins_system_settings_wecom_notification_content_path, params: { notification_content: { revision: content.revision, restore: "1" } }
      assert_response :forbidden
    end
  end
end

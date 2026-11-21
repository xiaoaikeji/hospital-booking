require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationContentsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @account = App.create!(provider: "wechat", appid: "wxActivity")
  end
  teardown { remove_wechat_stubs }

  def input(texts) = texts.each_with_index.map { |text, i| { id: "text_#{i}", type: "text", content: { text: text } } }

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

  test "超长业务数据按企微字节上限拆条，顺序和去重键稳定" do
    target = Notifications::Channels::WecomGroup.target("local-test-activity-group")
    text = "医院通知" * 500
    Sidekiq.testing!(:fake) do
      task = Notifications.dispatch(event: "activity_start", subject: @account, target: target,
        messages: input(["{activity_name}", "下一条"]), idempotency_key: "activity:long", data: {activity_name: text, starts_at: Time.current})
      parts = task.messages.map { |m| m.dig("content", "text") }
      assert parts.all? { |part| part.valid_encoding? && part.bytesize <= 2048 }
      assert_equal text + "下一条", parts.join
    end
  end
end

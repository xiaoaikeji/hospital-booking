# 业务决定事件、目标、真实数据和触发时间；发送任务只使用创建时的快照。
module Notifications
  class Error < StandardError; end

  class FieldError < Error
    def initialize(message, field:, message_index: nil)
      super(message)
      @field = field
      @message_index = message_index
    end

    def feedback = { error: message, field: @field, message_index: @message_index }.compact
  end

  def self.rejection_message(channel, code)
    code = Integer(code.to_s, 10, exception: false)
    provider = channel == "wecom_group" ? "企业微信" : "微信"
    hint = case [ channel, code ]
    when [ "wecom_group", 93000 ] then "请核对群机器人设置"
    when [ "wechat_official_account", 45015 ] then "超出微信客服消息的可回复时限"
    end
    [ "#{provider}拒绝发送#{"（#{code}）" if code}", hint ].compact.join("，")
  end

  def self.dispatch(event:, subject:, target:, messages:, idempotency_key:, scheduled_at: nil, data: nil)
    return if target.blank?
    raise Error, "请提供事件去重标识" if idempotency_key.blank?
    target_data = target.deep_stringify_keys
    identity = target_data.slice("channel_key", "app_id", "appid", "user_app_id", "callback_id")
    key = Digest::SHA256.hexdigest([ event, subject.class.name, subject.id, identity.sort.to_h, idempotency_key ].to_json)
    existing = Notification.find_by(idempotency_key: key)
    return existing if existing
    wecom = target_data["channel_type"] == "wecom_group"
    if data
      messages = Variables.render(messages, fields: EventCatalog.fetch(event).fetch("fields"), data: data,
        max_text_bytes: wecom ? nil : Channels::WecomGroup::MAX_TEXT_BYTES)
      return if messages.empty?
    end
    messages = Channels::WecomGroup.split_messages(messages) if wecom
    Notification.create_or_find_by!(idempotency_key: key) do |row|
      row.assign_attributes(event: event, subject: subject, status: "pending", scheduled_at: scheduled_at,
        payload: { "target" => target_data, "messages" => messages.map(&:deep_stringify_keys) })
    end
  end

  def self.retry_failed!(notification, ids:, actor:, request: nil)
    Notification.connection_pool.with_connection do |db|
      lock = "hashtextextended('booking.notification:#{Integer(notification.id)}', 0)"
      raise Error, "该通知正在发送，请稍后查看结果" unless db.select_value("SELECT pg_try_advisory_lock(#{lock})")
      begin
        notification.with_lock do
          selected = Array(ids).map(&:to_s).uniq
          raise Error, "只能补发已明确失败的消息" if selected.empty? || (selected - notification.retryable_ids).any?
          rows = notification.results.deep_dup
          rows.each do |r|
            next unless selected.include?(r["message_id"])
            history = r.fetch("history", []) + [ r.except("history", "message_id") ]
            r.merge!("status" => "pending", "history" => history)
          end
          notification.update!(status: "pending", sent_at: nil, response_data: notification.response_data.merge("messages" => rows))
          Log.record!(category: "notification", action: "notification.retry", actor: actor, target: notification,
            request: request, details: { message_ids: selected })
        end
      ensure
        db.execute("SELECT pg_advisory_unlock(#{lock})")
      end
    end
    notification.enqueue
  rescue Error => error
    Log.record!(category: "notification", action: "notification.retry", actor: actor, target: notification,
      request: request, status: "failed", details: { reason: error.message })
    raise
  end
end

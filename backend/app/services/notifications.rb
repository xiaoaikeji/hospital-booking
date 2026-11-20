# 业务决定事件、目标、真实数据和触发时间；发送任务只使用创建时的快照。
module Notifications
  class Error < StandardError; end

  def self.dispatch(event:, subject:, target:, messages:, idempotency_key:, scheduled_at: nil, data: nil)
    return if target.blank?
    raise Error, "请提供事件去重标识" if idempotency_key.blank?
    identity = target.deep_stringify_keys.slice("channel_key", "app_id", "appid", "user_app_id", "callback_id")
    key = Digest::SHA256.hexdigest([ event, subject.class.name, subject.id, identity.sort.to_h, idempotency_key ].to_json)
    existing = Notification.find_by(idempotency_key: key)
    return existing if existing
    if data
      messages = Variables.render(messages, fields: EventCatalog.fetch(event).fetch("fields"), data: data)
      return if messages.empty?
    end
    Notification.create_or_find_by!(idempotency_key: key) do |row|
      row.assign_attributes(event: event, subject: subject, status: "pending", scheduled_at: scheduled_at,
        payload: { "target" => target.deep_stringify_keys, "messages" => messages.map(&:deep_stringify_keys) })
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

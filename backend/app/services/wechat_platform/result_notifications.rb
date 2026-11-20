module WechatPlatform
  module ResultNotifications
    def self.audit(round)
      if round.saved_change_to_status? && MiniProgramAudit::PENDING.include?(round.status_before_last_save) &&
          %w[delayed passed rejected].include?(round.status) && round.audit_id.present?
        reason = { "rejected" => round.rejection_reason, "delayed" => round.delay_reason }[round.status]
        record(round.app, round.status, "audit:#{round.id}:#{round.status}",
          "版本" => round.version, "审核单号" => round.audit_id, "原因" => reason)
      end
      if round.saved_change_to_publication? && %w[published failed].include?(round.publication)
        record(round.app, round.publication, "publication:#{round.id}:#{round.publication}",
          "版本" => round.version, "审核单号" => round.audit_id, "错误码" => (round.error_code if round.publication == "failed"))
      end
    end

    def self.violation(violation)
      record(violation.app, "violation", "violation:#{violation.id}",
        "违规单号" => violation.record_number, "原因" => violation.reason, "规则" => violation.rule_name)
    end

    def self.appeal(appeal)
      violation = appeal.wechat_violation
      record(violation.app, "appeal_#{appeal.status}", "appeal:#{appeal.id}:#{appeal.status}",
        "申诉单号" => appeal.number, "违规单号" => violation.record_number, "原因" => appeal.reason)
    end

    def self.category(app, first, second, result, occurred_at)
      record(app, "category_#{result}", "category:#{first}:#{second}:#{result}:#{occurred_at}",
        "一级类目 ID" => first, "二级类目 ID" => second)
    end

    def self.record(app, kind, event_key, fields)
      return unless NotificationSettings.new.enabled?(kind)
      content = NotificationContents.new(kind)
      variables = NotificationContents.data(app, kind, fields)
      messages = Notifications::Variables.render(content.messages, fields: NotificationContents.fields(kind), data: variables)
      return if messages.empty?
      WechatNotificationEvent.transaction do
        event = WechatNotificationEvent.create_or_find_by!(app: app, event_key: event_key) do |row|
          row.assign_attributes(kind: kind, message: messages.map { |item| item.dig("content", "text") }.join("\n\n"), status: "pending")
        end
        if event.previously_new_record?
          Notifications.dispatch(event: kind, subject: event,
            target: Notifications::Channels::WecomGroup.target(NotificationSettings.new.key, name: "微信审核结果企微群"),
            messages: messages,
            idempotency_key: event_key)
        end
      end
    rescue Notifications::Error, ActiveRecord::ActiveRecordError, IntegrationSettings::ConfigurationError => error
      Rails.logger.warn("微信通知登记失败 app_id=#{app.id} kind=#{kind} error=#{error.class.name}")
    end

    def self.deliver(id)
      event = WechatNotificationEvent.find_by(id: id)
      return unless event&.status == "pending"
      settings = NotificationSettings.new
      task = Notification.find_by(subject: event)
      if task
        if settings.enabled?(event.kind)
          Notifications::Delivery.run(task.id)
          event.notification_delivery_finished!(task.reload)
        else
          task.update!(status: "failed", error_message: "通知类型已关闭，未发送")
          event.update!(status: "skipped")
        end
        return
      end
      # 升级前任务没有目标快照，保留旧记录和原有发送约定，不推断历史目标。
      status = settings.enabled?(event.kind) ? "sending" : "skipped"
      claimed = WechatNotificationEvent.where(id: id, status: "pending").update_all(status: status, updated_at: Time.current)
      return unless claimed == 1 && status == "sending"
      code = Wecom::WebhookClient.new.send_text(settings.key, event.message)
      event.update!(status: code.zero? ? "sent" : "failed", error_code: code.nonzero?)
    rescue HttpConnection::Unavailable
      event.update!(status: "unknown")
    end
  end
end

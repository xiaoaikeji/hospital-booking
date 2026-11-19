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
      lines = { "应用" => app.display_name, "AppID" => app.appid }.merge(fields).merge("时间" => Time.current.strftime("%F %T"))
      message = [NotificationSettings::LABELS.fetch(kind)]
      lines.each do |label, raw|
        next if raw.blank?
        value = ActionController::Base.helpers.strip_tags(raw.to_s.gsub(/<br\s*\/?>/i, "\n")).strip
        message << "#{label}：#{value}" if value.present?
      end
      WechatNotificationEvent.create_or_find_by!(app: app, event_key: event_key) do |event|
        event.assign_attributes(kind: kind, message: message.join("\n"), status: "pending")
      end
    rescue ActiveRecord::ActiveRecordError, IntegrationSettings::ConfigurationError => error
      Rails.logger.warn("微信通知登记失败 app_id=#{app.id} kind=#{kind} error=#{error.class.name}")
    end

    def self.deliver(id)
      event = WechatNotificationEvent.find_by(id: id)
      return unless event&.status == "pending"
      settings = NotificationSettings.new
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

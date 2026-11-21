module Notifications
  class WecomSettings
    include ActiveModel::Validations

    class InvalidKey < Error; end

    GROUP = "wechat_notifications"
    ENV_KEY = "WECOM_WEBHOOK_KEY"
    attr_reader :key, :source

    def initialize(row = Setting.find_by(key: GROUP))
      data = row&.settings || {}
      @stored_key = data["webhook_key"]
      @stored_key_present = data.key?("webhook_key")
      @key, @source = [
        [Setting.decode_value(GROUP, "webhook_key", @stored_key), "加密数据库"],
        [ENV[ENV_KEY], "环境变量"],
        [Rails.application.credentials.dig(:wechat_notifications, :webhook_key), "Rails credentials"]
      ].find { |value, _| value.present? } || [nil, "未配置"]
    rescue IntegrationSettings::ConfigurationError
      @key_unreadable = true
      @source = "系统配置（解密失败）"
    end

    def stored_key? = @stored_key_present
    def key_unreadable? = @key_unreadable

    def revision
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, [@stored_key, key, source].to_json)
    end

    def save(input, actor:, request:)
      Setting.transaction do
        Setting.connection.execute("SELECT pg_advisory_xact_lock(71020012)")
        row = Setting.find_or_create_by!(key: GROUP)
        row.lock!
        current = self.class.new(row)
        raise Error, "配置已变化，请刷新后再保存" unless input[:revision] == current.revision
        changed = []
        if input[:clear_key] == "1"
          changed << "webhook_key" if row.settings.key?("webhook_key")
          row.write_value("webhook_key", nil)
        else
          if current.key_unreadable? && input[:webhook_key].blank?
            raise InvalidKey, "请重新填写机器人 Key 或清除系统配置"
          end
          if input[:webhook_key].present? && input[:webhook_key].strip != current.key
            replacement = normalize_key(input[:webhook_key])
            if replacement != current.key
              if current.key.present? && input[:same_robot] == "1"
                Notifications::Channels::WecomGroup.rotate!(current.key, replacement)
                changed << "same_robot"
              end
              row.write_value("webhook_key", replacement)
              changed << "webhook_key"
            end
          end
        end
        Notifications::Channels::WecomGroup.validate_key!(self.class.new(row).key)
        row.save!
        Log.record!(action: "wechat.notification_settings", category: "wechat", actor: actor, target: row, request: request,
          details: { fields: changed })
      end
      true
    rescue Error, IntegrationSettings::ConfigurationError, ActiveRecord::RecordInvalid => e
      message = e.is_a?(Error) ? e.message : "通知设置未保存，请核对部署配置"
      errors.add(e.is_a?(InvalidKey) ? :webhook_key : :base, message)
      Log.record!(action: "wechat.notification_settings", category: "wechat", actor: actor, request: request, status: "failed",
        details: { reason: message })
      false
    end

    private

    def normalize_key(raw)
      value = raw.to_s.strip
      value = value.delete_prefix("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=")
      raise InvalidKey, "请填写有效的机器人 Key 或完整 Webhook 地址" unless value.match?(/\A[A-Za-z0-9-]{8,64}\z/)
      value
    end
  end
end

module WechatPlatform
  class NotificationSettings
    include ActiveModel::Validations

    class InvalidKey < Error; end

    GROUP = "wechat_notifications"
    ENV_KEY = "WECOM_WEBHOOK_KEY"
    LABELS = {
      "passed" => "审核通过", "rejected" => "审核未通过", "delayed" => "审核延后",
      "published" => "发布成功", "failed" => "发布失败", "violation" => "新增违规",
      "appeal_1" => "申诉处理中", "appeal_2" => "申诉不通过", "appeal_3" => "申诉通过",
      "category_2" => "类目审核未通过", "category_3" => "类目审核通过"
    }.freeze
    attr_reader :key, :source, :kinds, :pull

    def initialize(row = Setting.find_by(key: GROUP))
      data = row&.settings || {}
      @pull = data["pull_violations"] == true
      @kinds = Array(data["kinds"]) & LABELS.keys
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
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, [@stored_key, key, source, pull, kinds.sort].to_json)
    end

    def enabled?(kind)
      return false unless kinds.include?(kind)
      raise IntegrationSettings::ConfigurationError, "企业微信群机器人 Key 无法解密" if key_unreadable?
      key.present?
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
          chosen = Array(input[:kinds]).compact_blank.uniq.sort
          raise Error, "通知类型无效" unless (chosen - LABELS.keys).empty?
          pull_enabled = input[:pull_violations] == "1"
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
          changed << "kinds" if chosen != current.kinds.sort
          changed << "pull_violations" if pull_enabled != current.pull
          row.write_value("kinds", chosen)
          row.write_value("pull_violations", pull_enabled)
        end
        Notifications::Channels::WecomGroup.validate_key!(self.class.new(row).key)
        row.save!
        Log.record!(action: "wechat.notification_settings", category: "wechat", actor: actor, target: row, request: request,
          details: { fields: changed })
      end
      true
    rescue Error, Notifications::Error, IntegrationSettings::ConfigurationError, ActiveRecord::RecordInvalid => e
      message = (e.is_a?(Error) || e.is_a?(Notifications::Error)) ? e.message : "通知设置未保存，请核对部署配置"
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

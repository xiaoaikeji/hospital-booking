module WechatPlatform
  class NotificationSettings
    GROUP = "wechat_notifications"
    ENV_KEY = "WECOM_WEBHOOK_KEY"
    LABELS = {
      "passed" => "审核通过", "rejected" => "审核未通过", "delayed" => "审核延后",
      "published" => "发布成功", "failed" => "发布失败", "violation" => "新增违规",
      "appeal_1" => "申诉处理中", "appeal_2" => "申诉不通过", "appeal_3" => "申诉通过",
      "category_2" => "类目审核未通过", "category_3" => "类目审核通过"
    }.freeze
    attr_reader :key, :source, :kinds, :pull, :error

    def initialize(row = Setting.find_by(key: GROUP))
      data = row&.settings || {}
      @pull = data["pull_violations"] == true
      @kinds = Array(data["kinds"]) & LABELS.keys
      @key, @source = [
        [Setting.decode_value(GROUP, "webhook_key", data["webhook_key"]), "加密数据库"],
        [ENV[ENV_KEY], "环境变量"],
        [Rails.application.credentials.dig(:wechat_notifications, :webhook_key), "Rails credentials"]
      ].find { |value, _| value.present? } || [nil, "未配置"]
    end

    def revision
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, [key, source, pull, kinds.sort].to_json)
    end

    def enabled?(kind) = key.present? && kinds.include?(kind)

    def save(input, actor:, request:)
      Setting.transaction do
        Setting.connection.execute("SELECT pg_advisory_xact_lock(71020012)")
        row = Setting.find_or_create_by!(key: GROUP)
        row.lock!
        current = self.class.new(row)
        raise Error, "配置已变化，请刷新后再保存" unless input[:revision] == current.revision
        chosen = Array(input[:kinds]).compact_blank.uniq.sort
        raise Error, "通知类型无效" unless (chosen - LABELS.keys).empty?
        pull_enabled = input[:pull_violations] == "1"
        changed = []
        if input[:clear_key] == "1"
          changed << "webhook_key" if row.settings.key?("webhook_key")
          row.write_value("webhook_key", nil)
        elsif input[:webhook_key].present? && input[:webhook_key].strip != current.key
          value = normalize_key(input[:webhook_key])
          row.write_value("webhook_key", value)
          changed << "webhook_key"
        end
        changed << "kinds" if chosen != current.kinds.sort
        changed << "pull_violations" if pull_enabled != current.pull
        row.write_value("kinds", chosen)
        row.write_value("pull_violations", pull_enabled)
        row.save!
        Log.record!(action: "wechat.notification_settings", category: "wechat", actor: actor, target: row, request: request,
          details: { fields: changed })
      end
      true
    rescue Error, IntegrationSettings::ConfigurationError, ActiveRecord::RecordInvalid => e
      @error = e.is_a?(Error) ? e.message : "通知设置未保存，请核对部署配置"
      Log.record!(action: "wechat.notification_settings", category: "wechat", actor: actor, request: request, status: "failed",
        details: { reason: @error })
      false
    end

    private

    def normalize_key(raw)
      value = raw.to_s.strip
      value = value.delete_prefix("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=")
      raise Error, "请填写企业微信群机器人的有效 Key 或完整 Webhook 地址" unless value.match?(/\A[A-Za-z0-9-]{8,64}\z/)
      value
    end
  end
end

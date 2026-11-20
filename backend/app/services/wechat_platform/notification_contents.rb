module WechatPlatform
  # 微信审核等业务只声明数据；变量替换、任务快照和渠道发送由通知底座负责。
  class NotificationContents
    FIELD_MAP = { "版本" => "version", "审核单号" => "audit_id", "原因" => "reason", "错误码" => "error_code",
      "违规单号" => "record_number", "规则" => "rule_name", "申诉单号" => "appeal_number",
      "一级类目 ID" => "first_category_id", "二级类目 ID" => "second_category_id" }.freeze
    GROUP_FIELDS = {
      "release" => %w[version audit_id reason error_code], "violation" => %w[record_number reason rule_name],
      "appeal" => %w[appeal_number record_number reason], "category" => %w[first_category_id second_category_id]
    }.freeze
    FIELD_LABELS = FIELD_MAP.invert.freeze

    def self.fields(kind)
      group = if kind.start_with?("appeal_") then "appeal"
      elsif kind.start_with?("category_") then "category"
      elsif kind == "violation" then "violation"
      else "release"
      end
      common = { "result" => { "label" => "通知结果", "example" => NotificationSettings::LABELS.fetch(kind) },
        "app_name" => { "label" => "应用名称", "example" => "示例小程序" }, "appid" => { "label" => "应用 AppID", "example" => "wxExampleMini" } }
      keys = case kind
      when "passed", "published" then %w[version audit_id]
      when "rejected", "delayed" then %w[version audit_id reason]
      when "failed" then %w[version audit_id error_code]
      else GROUP_FIELDS.fetch(group)
      end
      keys.each do |key|
        example = { "version" => "1.2.0", "audit_id" => "10001", "reason" => "请补充页面说明", "error_code" => "85051",
          "record_number" => "record-demo", "rule_name" => "服务规范", "appeal_number" => "appeal-demo",
          "first_category_id" => "1", "second_category_id" => "2" }.fetch(key)
        common[key] = { "label" => FIELD_LABELS.fetch(key), "example" => example, "optional" => true,
          "hint" => "本次事件没有该数据时，省略包含它的整行" }
      end
      common.merge("time" => { "label" => "事件通知时间", "example" => "2026-11-20 14:00:00" })
    end

    def self.defaults(kind)
      fields = fields(kind)
      lines = [ "{result}", "应用：{app_name}", "AppID：{appid}" ]
      fields.except("result", "app_name", "appid", "time").each { |key, field| lines << "#{field['label']}：{#{key}}" }
      lines << "时间：{time}"
      [ { "id" => "msg_1", "type" => "text", "content" => { "text" => lines.join("\n") } } ]
    end

    def self.data(app, kind, fields)
      result = { "result" => NotificationSettings::LABELS.fetch(kind), "app_name" => app.display_name,
        "appid" => app.appid, "time" => Time.current.strftime("%F %T") }
      fields.each do |label, raw|
        key = FIELD_MAP.fetch(label)
        result[key] = raw.nil? ? nil : ActionController::Base.helpers.strip_tags(raw.to_s.gsub(/<br\s*\/?>/i, "\n")).strip
      end
      result
    end

    attr_reader :kind

    def initialize(kind)
      raise Notifications::Error, "通知事件无效" unless NotificationSettings::LABELS.key?(kind)
      @kind = kind
    end

    def stored = Setting.find_by(key: "notification")&.settings&.dig("wechat_results", kind)
    def messages = stored || self.class.defaults(kind)
    def revision = Digest::SHA256.hexdigest([ kind, messages ].to_json)

    def save!(rows, revision:, actor:, request: nil, restore: false)
      raise Notifications::Error, "需要超级管理员权限" unless actor.super_admin?
      Setting.transaction do
        Setting.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
        row = Setting.find_or_create_by!(key: "notification")
        row.lock!
        raise Notifications::Error, "通知文案已变化，请刷新后再保存" unless revision == self.revision
        values = row.settings.deep_dup
        values["wechat_results"] ||= {}
        if restore
          values["wechat_results"].delete(kind)
        else
          values["wechat_results"][kind] = normalize(rows)
        end
        changed = values != row.settings
        row.update!(settings: values)
        Log.record!(category: "notification", action: "notification.wecom_content", actor: actor, target: row, request: request,
          details: { event: kind, fields: changed ? [ "messages" ] : [] })
      end
    rescue Notifications::Error => error
      Log.record!(category: "notification", action: "notification.wecom_content", actor: actor, request: request, status: "failed", details: { event: kind, reason: error.message })
      raise
    end

    private

    def normalize(rows)
      raise Notifications::Error, "请新增 1～8 条文字消息" unless rows.is_a?(Array) && rows.size.between?(1, 8)
      messages = rows.map do |raw|
        raise Notifications::Error, "消息格式无效" unless raw.is_a?(Hash)
        item = raw.deep_stringify_keys
        raise Notifications::Error, "消息格式无效" unless item["content"].is_a?(Hash)
        text = item.dig("content", "text").to_s.gsub("\r\n", "\n")
        raise Notifications::Error, "企微通知仅支持文字，每条 1～2048 字节" unless item["type"] == "text" && text.strip.present? && text.bytesize <= 2048
        id = item["id"].presence || SecureRandom.uuid
        raise Notifications::Error, "消息标识无效" unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9:_-]{1,100}\z/)
        { "id" => id, "type" => "text", "content" => { "text" => text } }
      end
      raise Notifications::Error, "消息标识重复" unless messages.map { |m| m["id"] }.uniq.size == messages.size
      Notifications::Variables.validate!(messages, fields: self.class.fields(kind))
      messages
    end
  end
end

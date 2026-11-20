module Notifications
  class TemplateMessages
    def initialize(app)
      @app = app
      @config = AccountConfiguration.new(app)
    end

    def templates
      raise Error, "请先完成本公众号的平台授权" unless @app.platform_authorized?
      WechatPlatform::AuthorizerToken.with_token(@app) { |token| Wechat::OfficialAccountMessageClient.new.templates(token) }
    end

    def self.fields(content)
      content.to_s.scan(/([^\n{}]*)\{\{\s*(\w+)\.DATA\s*\}\}/).map { |label, key| [ key, label.strip.sub(/[:：]\z/, "").presence || key ] }.to_h
    end

    def self.guess(event, key, label)
      options = EventCatalog.fetch(event).fetch("fields")
      matching = options.find { |_, field| label.include?(field["label"]) || field["label"].include?(label) }
      matching ||= options.find { |_, field| field["type"] == "time" } if key.match?(/\A(time|date)\d*\z/)
      matching&.first || options.keys.first
    end

    def bind!(event:, template_id:, mapping:, revision:, actor:, request: nil)
      definition = EventCatalog.for_templates.fetch(event) { raise Error, "该事件不能绑定微信模板消息" }
      template = templates.find { |t| t["template_id"] == template_id } || raise(Error, "请选择本公众号已有的微信模板")
      fields = self.class.fields(template["content"])
      mapping = mapping.to_h.stringify_keys
      unless fields.any? && mapping.keys.sort == fields.keys.sort && mapping.values.all? { |value| definition["fields"].key?(value) }
        raise Error, "请为每个微信字段选择业务数据"
      end
      @config.update!(revision, actor: actor, request: request, action: "notification.template_bind") do |data|
        data["template_bindings"] ||= {}
        data["template_bindings"][event] = { "template_id" => template_id, "title" => template["title"], "fields" => fields, "mapping" => mapping }
      end
    end

    # 收件人、计划时间、真实数据和跳转由业务提供。只读已确认绑定，不再访问模板列表或重新猜字段。
    def deliver(event:, subject:, recipients:, data:, idempotency_key:, scheduled_at: nil, jump: {})
      definition = EventCatalog.for_templates.fetch(event) { raise Error, "该事件不能绑定微信模板消息" }
      binding = @config.data.dig("template_bindings", event) || raise(Error, "请先为本公众号配置微信模板消息")
      values = data.stringify_keys
      raise Error, "业务数据缺少必要字段" unless definition["fields"].keys.all? { |key| values[key].present? }
      destination = normalize_jump(jump.deep_stringify_keys)
      identities = Array(recipients).map do |recipient|
        id = recipient.respond_to?(:id) ? recipient.id : recipient
        UserApp.for_app(@app).find(id)
      end.uniq(&:id)
      raise Error, "收件人未关注当前公众号" unless identities.all? { |fan| fan.official_account_fan&.subscribed? }
      content = { "template_id" => binding["template_id"], "data" => binding.fetch("mapping").to_h do |key, value|
        [ key, { "value" => self.class.format_value(key, values.fetch(value)) } ]
      end }.merge(destination)
      Notification.transaction do
        identities.map do |identity|
          Notifications.dispatch(event: event, subject: subject, target: { channel_type: "wechat_official_account",
            channel_key: "official_account_#{@app.id}", app_id: @app.id, appid: @app.appid,
            user_app_id: identity.id, label: "#{@app.display_name} · 用户 #{identity.user.user_no}" },
            messages: [ { id: "template", type: "template", content: content, title: binding["title"], fields: binding["fields"] } ], idempotency_key: idempotency_key, scheduled_at: scheduled_at)
        end
      end
    end

    def self.format_value(key, value)
      type = key.sub(/\d+\z/, "")
      if type.in?(%w[time date])
        time = value.respond_to?(:strftime) ? value : Time.zone.parse(value.to_s)
        raise Error, "业务时间格式无效" unless time
        return time.strftime(type == "date" ? "%F" : "%Y年%m月%d日 %H:%M")
      end
      text = value.to_s.gsub(/[[:cntrl:]]/, " ").strip
      max = { "thing" => 20, "character_string" => 32, "phrase" => 5, "name" => 10 }.fetch(type, 20)
      raise Error, "模板字段内容为空" if text.blank?
      text.first(max)
    rescue ArgumentError
      raise Error, "业务时间格式无效"
    end

    private

    def normalize_jump(jump)
      return {} if jump.empty?
      if jump["url"]
        uri = URI.parse(jump["url"]) rescue nil
        raise Error, "跳转地址无效" unless uri.is_a?(URI::HTTP) && uri.host.present?
        { "url" => jump["url"] }
      elsif jump["miniprogram"].is_a?(Hash)
        mini = jump["miniprogram"]
        raise Error, "跳转小程序或页面无效" unless App.wechat_mini_programs.exists?(appid: mini["appid"]) && mini["pagepath"].is_a?(String) && mini["pagepath"].size.between?(1, 255)
        { "miniprogram" => mini.slice("appid", "pagepath") }
      else
        raise Error, "跳转配置无效"
      end
    end
  end
end

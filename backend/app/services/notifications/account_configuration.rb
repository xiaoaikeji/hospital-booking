module Notifications
  # 公众号运营配置均在 settings.notification，账号之间没有通用回复或素材回退。
  class AccountConfiguration
    MODES = { "none" => "仅统计来源", "welcome" => "仅发欢迎语", "reply" => "仅发专属回复", "both" => "欢迎语和专属回复都发" }.freeze
    attr_reader :app

    def initialize(app)
      raise Error, "请选择微信公众号" unless app.provider == "wechat" && app.app_type == "official_account"
      @app = app
    end

    def data
      Setting.find_by(key: "notification")&.settings&.dig("accounts", app.appid) || {}
    end

    def revision = Digest::SHA256.hexdigest(data.to_json)
    def replies = data.fetch("replies", {})
    def reply(id) = replies[id.to_s] || raise(ActiveRecord::RecordNotFound)
    def code_binding(id) = data.fetch("qrcodes", {}).fetch(id.to_s, { "mode" => "none" })
    def self.menu_key(id) = "reply_#{id}"

    def impacts(id)
      entries = []
      menu = OfficialAccountMenu.find_by(app: app)
      [ [ "线上菜单", menu&.buttons ], [ "待核实菜单", menu&.pending_buttons ] ].each do |label, nodes|
        Array(nodes).flat_map { |n| [ n, *n.fetch("sub_button", []) ] }.each do |node|
          entries << "#{label}：#{node['name']}" if node["key"] == self.class.menu_key(id)
        end
      end
      config = data
      names = OfficialAccountQrcode.where(app: app).pluck(:id, :name).to_h
      config.fetch("qrcodes", {}).each do |key, binding|
        entries << "渠道码：#{names[key.to_i]}" if binding["reply_id"] == id && binding["mode"].in?(%w[reply both])
      end
      %w[follow_first follow_again].each { |kind| entries << (kind == "follow_first" ? "首次关注" : "再次关注") if config[kind] == id }
      config.fetch("keywords", []).each { |rule| entries << "关键词：#{rule['words']}" if rule["reply_id"] == id }
      entries
    end

    def impact_revision(id) = Digest::SHA256.hexdigest([ revision, impacts(id) ].to_json)

    def save_reply!(input, actor:, request: nil)
      input = input.deep_stringify_keys
      id = input["id"].presence
      source_id = id
      only = input["scope"] == "only"
      fields = []
      update!(input["revision"], actor: actor, request: request, action: "notification.reply_save", fields: fields) do |config|
        previous = id ? config.fetch("replies", {}).fetch(id) { raise Error, "回复内容不存在" } : nil
        if id && !only && input["impact_revision"] != impact_revision(id)
          raise Error, "受影响入口已变化，请重新核对后保存"
        end
        id = SecureRandom.uuid if !id || only
        messages = normalize_messages(input["messages"], previous)
        name = input["name"].to_s.strip
        raise FieldError.new("请填写回复内容名称", field: "name") unless name.size.between?(1, 60)
        config["replies"] ||= {}
        interval = SendInterval.normalize(input.fetch("send_interval") { previous&.dig("send_interval") })
        saved = { "name" => name, "messages" => messages, "variables_version" => 1, "send_interval" => interval }.compact
        config["replies"][id] = saved
        before = only ? {} : previous || {}
        fields.concat((before.keys | saved.keys).select { |key| before[key] != saved[key] })
        if only && input["qrcode_id"].present?
          code = OfficialAccountQrcode.where(app: app).find(input["qrcode_id"])
          binding = config.fetch("qrcodes", {}).fetch(code.id.to_s, { "mode" => "none" })
          if source_id && binding["reply_id"] != source_id
            raise Error, "请先在渠道码页面保存所选回复内容，再打开编辑"
          end
          config["qrcodes"] ||= {}
          fields << "qrcodes"
          config["qrcodes"][code.id.to_s] = binding.merge("reply_id" => id)
        end
      end
      { id: id, key: self.class.menu_key(id), name: reply(id)["name"], messages: reply(id)["messages"], revision: revision,
        qrcode_id: (input["qrcode_id"] if only) }
    end

    def save_rules!(input, actor:, request: nil)
      input = input.deep_stringify_keys
      update!(input["revision"], actor: actor, request: request, action: "notification.rules_save") do |config|
        %w[follow_first follow_again].each do |key|
          value = input[key].presence
          require_reply!(config, value) if value
          config[key] = value
        end
        rules = Array(input["keywords"]).reject { |r| r["words"].to_s.strip.empty? }
        raise Error, "关键词规则最多 50 条" if rules.size > 50
        config["keywords"] = rules.map do |rule|
          raise Error, "关键词匹配方式无效" unless rule["match"].in?(%w[exact contain])
          raise Error, "关键词过长" if rule["words"].to_s.size > 500
          require_reply!(config, rule["reply_id"])
          rule.slice("words", "match", "reply_id")
        end
      end
    end

    def validate_code_binding!(mode:, reply_id:, revision:)
      raise Error, "配置已变化，请刷新后再保存" unless revision == self.revision
      raise Error, "扫码配置无效" unless MODES.key?(mode)
      require_reply!(data, reply_id) if mode.in?(%w[reply both])
    end

    def bind_code!(code, mode:, reply_id:, revision:, actor:, request: nil)
      raise ActiveRecord::RecordNotFound unless code.app_id == app.id
      update!(revision, actor: actor, request: request, action: "notification.code_bind") do |config|
        raise Error, "扫码配置无效" unless MODES.key?(mode)
        require_reply!(config, reply_id) if mode.in?(%w[reply both])
        bindings = config["qrcodes"] ||= {}
        key = code.id.to_s
        saved_reply = reply_id.nil? ? bindings.dig(key, "reply_id") : reply_id.presence
        bindings[key] = { "mode" => mode, "reply_id" => saved_reply }
      end
    end

    def update!(expected, actor:, request:, action:, fields: nil)
      Setting.transaction do
        Setting.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
        row = Setting.find_or_create_by!(key: "notification")
        row.lock!
        raise Error, "配置已变化，请刷新后再保存" unless expected == revision
        config = data.deep_dup
        yield config
        values = row.settings.deep_dup
        values["accounts"] ||= {}
        values["accounts"][app.appid] = config
        row.update!(settings: values)
        Log.record!(category: "notification", action: action, actor: actor, target: app, request: request,
          details: { fields: fields || [ action.delete_prefix("notification.") ] })
      end
    rescue Error => error
      Log.record!(category: "notification", action: action, actor: actor, target: app, request: request, status: "failed", details: { reason: error.message })
      raise
    end

    private

    def require_reply!(config, id)
      raise Error, "请选择本公众号的回复内容" unless config.fetch("replies", {}).key?(id.to_s)
    end

    def normalize_messages(rows, previous)
      raise Error, "请新增 1～8 条消息" unless rows.is_a?(Array) && rows.size.between?(1, 8)
      messages = rows.each_with_index.map do |row, index|
        raise Error, "消息格式无效" unless row.is_a?(Hash) && row["content"].is_a?(Hash)
        content = row["content"]
        case row["type"]
        when "text"
          text = content["text"].to_s.gsub("\r\n", "\n")
          unless text.bytesize.between?(1, 2048) && text.strip.present?
            raise FieldError.new("文字应为 1～2048 字节", field: "text", message_index: index)
          end
          content = { "text" => text }
        when "miniprogrampage"
          unless App.wechat_mini_programs.exists?(appid: content["appid"])
            raise FieldError.new("请选择当前机构的小程序", field: "appid", message_index: index)
          end
          unless content["title"].to_s.strip.size.between?(1, 60)
            raise FieldError.new("请填写 1～60 字的卡片标题", field: "title", message_index: index)
          end
          unless content["pagepath"].to_s.strip.size.between?(1, 255)
            raise FieldError.new("请填写 1～255 字的页面路径", field: "pagepath", message_index: index)
          end
          media = content["thumb_media_id"]
          old = Array(previous&.fetch("messages", nil)).any? { |m| m["type"] == "miniprogrampage" && m.dig("content", "thumb_media_id") == media }
          proof = Rails.application.message_verifier(:official_menu_resource).verified(row["proof"].to_s)
          unless media.present? && (old || proof == [ app.id, "card_cover", media ])
            raise FieldError.new("请向本公众号上传卡片封面", field: "thumb_media_id", message_index: index)
          end
          content = content.slice("title", "appid", "pagepath", "thumb_media_id")
        else raise Error, "仅支持文字和小程序卡片"
        end
        id = row["id"].presence || SecureRandom.uuid
        raise Error, "消息标识无效" unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9:_-]{1,100}\z/)
        { "id" => id, "type" => row["type"], "content" => content }
      end
      raise Error, "消息标识重复" unless messages.map { |m| m["id"] }.uniq.size == messages.size
      Variables.validate!(messages, fields: ReplyVariables::FIELDS)
      messages
    end
  end
end

module Notifications
  class OfficialAccountEvents
    def self.receive!(app, message)
      fields = message.slice("ToUserName", "FromUserName", "CreateTime", "MsgType", "Event", "EventKey", "Content", "MsgId")
      openid, seconds = fields.values_at("FromUserName", "CreateTime")
      raise ActionController::BadRequest, "公众号回调字段无效" unless openid.is_a?(String) && openid.size.between?(1, 150) && seconds.to_s.match?(/\A[1-9]\d{0,10}\z/)
      supported = fields["MsgType"] == "text" || (fields["MsgType"] == "event" && fields["Event"].in?(%w[subscribe unsubscribe SCAN CLICK]))
      return unless supported
      identity = fields["MsgId"].presence || fields.except("Content").to_json
      digest = Digest::SHA256.hexdigest(identity)
      sender = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, openid)
      # 相同粉丝的事件串行登记；重复推送返回已保存的同一个应答，不重复排消息。
      app.class.connection_pool.with_connection do |db|
        lock = "hashtextextended(#{db.quote("booking.oa_event:#{app.id}:#{sender}")}, 0)"
        raise Error, "该事件正在处理" unless db.select_value("SELECT pg_try_advisory_lock(#{lock})")
        begin
          row = OfficialAccountCallback.create_or_find_by!(app: app, digest: digest) do |record|
            record.assign_attributes(sender_digest: sender, message: fields.to_json)
          end
          new(row).process! unless row.processed_at
          row.reload.reply_xml
        ensure
          db.execute("SELECT pg_advisory_unlock(#{lock})")
        end
      end
    end

    def initialize(callback)
      @callback, @app, @message = callback, callback.app, callback.fields
      @config = AccountConfiguration.new(@app)
    end

    def process!
      prior = UserApp.for_app(@app).find_by(openid: @message["FromUserName"])&.official_account_fan
      subscribe = @message["Event"] == "subscribe"
      # 关注资料仍使用已交付的异步链路，不在微信五秒应答内等待外部资料接口。
      if @message["Event"].in?(%w[subscribe unsubscribe])
        key = @message["EventKey"].to_s
        scene = key.delete_prefix("qrscene_") if key.start_with?("qrscene_")
        OfficialAccountFanEvent.receive!(@app, @message["FromUserName"], @message["Event"], @message["CreateTime"].to_i, scene)
      end
      stale = prior&.event_at && prior.event_at.to_i > @message["CreateTime"].to_i
      config = @config.data
      groups = config.fetch("replies", {})
      selected = stale ? [] : selected_replies(prior, subscribe, config)
      values = ReplyVariables.values(@app, @message) if selected.any? { |id| groups[id]&.fetch("variables_version", nil) == 1 }
      xml = nil
      @callback.transaction do
        messages = selected.each_with_index.flat_map do |id, index|
          group = groups[id]
          next [] unless group
          content = group.fetch("messages").deep_dup
          content = Variables.render(content, fields: ReplyVariables::FIELDS, data: values) if group["variables_version"] == 1
          content.map do |message|
            message["id"] = "#{index}:#{message['id']}" if selected.size > 1
            message
          end
        end
        if messages.any?
          row = Notifications.dispatch(event: event_name, subject: @callback, target: {
            channel_type: "wechat_official_account", channel_key: "official_account_#{@app.id}", app_id: @app.id,
            appid: @app.appid, callback_id: @callback.id, label: "#{@app.display_name} · 本次互动粉丝" },
            messages: messages, idempotency_key: @callback.id.to_s)
          if messages.first["type"] == "text"
            xml = reply_text(messages.first.dig("content", "text"))
            row.update!(response_data: { "messages" => [ { "message_id" => messages.first["id"], "status" => "sending",
              "provider_state" => "passive_prepared", "stage" => "passive_response", "attempt_count" => 1,
              "last_attempt_at" => Time.current.iso8601 } ] })
          end
        end
        @callback.update!(reply_xml: xml, processed_at: Time.current)
      end
    end

    private

    def event_name = @message["MsgType"] == "text" ? "official_account.keyword" : "official_account.#{@message['Event'].downcase}"

    def selected_replies(prior, subscribe, data)
      if @message["MsgType"] == "text"
        word = @message["Content"].to_s.strip.downcase
        rule = data.fetch("keywords", []).find do |r|
          r["words"].to_s.split(/[,，]/).map(&:strip).reject(&:empty?).any? { |w| r["match"] == "contain" ? word.include?(w.downcase) : word == w.downcase }
        end
        return [ rule&.fetch("reply_id", nil) ].compact
      end
      if @message["Event"] == "CLICK"
        key = @message["EventKey"].to_s
        menu = OfficialAccountMenu.find_by(app: @app)
        nodes = [ *Array(menu&.buttons), *Array(menu&.pending_buttons) ].flat_map { |n| [ n, *n.fetch("sub_button", []) ] }
        return [] unless nodes.any? { |n| n["type"] == "click" && n["key"] == key }
        return [ key.delete_prefix("reply_") ] if key.start_with?("reply_")
        return [] # 保留旧菜单的 key，不把未知历史 key 猜成另一组回复。
      end
      return [] unless subscribe || @message["Event"] == "SCAN"
      previous_follows = OfficialAccountCallback.where(app: @app, sender_digest: @callback.sender_digest).where("id < ?", @callback.id)
      seen_before = prior || previous_follows.any? { |event| event.fields["Event"] == "subscribe" }
      welcome = data[seen_before ? "follow_again" : "follow_first"]
      scene = @message["EventKey"].to_s.delete_prefix("qrscene_")
      code = OfficialAccountQrcode.find_by(app: @app, scene: scene)
      return subscribe ? [ welcome ].compact : [] unless code
      binding = data.fetch("qrcodes", {}).fetch(code.id.to_s, { "mode" => "none" })
      case binding["mode"]
      when "welcome" then [ welcome ].compact
      when "reply" then [ binding["reply_id"] ].compact
      when "both" then [ welcome, binding["reply_id"] ].compact
      else []
      end
    end

    def reply_text(content)
      escape = ->(value) { value.to_s.gsub("]]>", "]]]]><![CDATA[>") }
      "<xml><ToUserName><![CDATA[#{escape.call(@message['FromUserName'])}]]></ToUserName>" \
        "<FromUserName><![CDATA[#{escape.call(@message['ToUserName'])}]]></FromUserName><CreateTime>#{Time.current.to_i}</CreateTime>" \
        "<MsgType><![CDATA[text]]></MsgType><Content><![CDATA[#{escape.call(content)}]]></Content></xml>"
    end
  end
end

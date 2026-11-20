module Notifications
  module Channels
    class WecomGroup
      MAX_TEXT_BYTES = 2048

      # 旧设置保留。每个已选机器人登记独立稳定键，之后改设置不会转发旧任务。
      def self.target(key, name: "企业微信群")
        fingerprint = credential_id(key)
        channel_key = with_channels do |channels|
          channel = usable_channel(channels, fingerprint)
          next channel if channel
          channels[fingerprint] = { "name" => name, "channel_type" => "wecom_group",
            "sequence_scope" => fingerprint, "webhook_key" => encrypted_key(key) }
          fingerprint
        end
        { "settings_key" => "notification", "channel_key" => channel_key, "channel_type" => "wecom_group", "sequence_scope" => channel_key, "label" => name }
      end

      def self.validate_key!(key)
        return if key.blank?

        channels = Setting.find_by(key: "notification")&.settings&.fetch("channels", {}) || {}
        usable_channel(channels, credential_id(key))
      end

      def self.split_text(text, max_bytes: MAX_TEXT_BYTES)
        parts = [ +"" ]
        text.to_s.each_char do |char|
          parts << +"" if parts.last.bytesize + char.bytesize > max_bytes && !parts.last.empty?
          parts.last << char
        end
        parts.reject(&:empty?)
      end

      def self.text_messages(text)
        split_text(text).map.with_index(1) { |part, i| { "id" => "msg_#{i}", "type" => "text", "content" => { "text" => part } } }
      end

      # 企微单条文本按 UTF-8 字节限制。超长消息按完整字符顺序拆条，保留原编排顺序和逐条回执。
      def self.split_messages(messages, max_bytes: MAX_TEXT_BYTES)
        rows = Array(messages).map(&:deep_stringify_keys)
        used_ids = rows.filter_map { |row| row["id"].presence }.to_set
        rows.flat_map do |row|
          next [ row ] unless row["type"] == "text" && row["content"].is_a?(Hash)
          text = row.dig("content", "text")
          next [ row ] unless text.is_a?(String) && text.bytesize > max_bytes
          base_id = row["id"].presence || "msg"
          split_text(text, max_bytes: max_bytes).each_with_index.map do |part, index|
            part_id = next_part_id(base_id, index + 1, used_ids)
            row.deep_dup.merge("id" => part_id, "content" => row["content"].merge("text" => part))
          end
        end
      end

      def self.rotate!(old_key, new_key)
        old_fingerprint = credential_id(old_key)
        new_fingerprint = credential_id(new_key)
        return if old_fingerprint == new_fingerprint
        with_channels do |channels|
          old_id = usable_channel(channels, old_fingerprint)
          if old_id.nil?
            old_id = old_fingerprint
            channels[old_id] = { "name" => "企业微信群", "channel_type" => "wecom_group",
              "sequence_scope" => old_id, "webhook_key" => encrypted_key(old_key) }
          end
          other = usable_channel(channels, new_fingerprint)
          if other && other != old_id
            raise Error, "新 Key 已登记在其他通知群"
          end
          channel = channels.fetch(old_id)
          retired = Array(channel["retired_credential_ids"]) | [old_fingerprint]
          channel.merge!("credential_id" => new_fingerprint, "webhook_key" => encrypted_key(new_key), "retired_credential_ids" => retired)
        end
      end

      def self.credential_id(key)
        "wecom_#{OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, key).first(24)}"
      end

      def self.encrypted_key(key) = { "ciphertext" => ActiveRecord::Encryption.encryptor.encrypt(key) }

      def self.channel_for(channels, fingerprint)
        channels.find { |id, row| row["channel_type"] == "wecom_group" && row.fetch("credential_id", id) == fingerprint }&.first
      end

      def self.usable_channel(channels, fingerprint)
        channel = channel_for(channels, fingerprint)
      return channel if channel

      if channels.key?(fingerprint) || channels.values.any? { |row| Array(row["retired_credential_ids"]).include?(fingerprint) }
        raise Error, "生效的机器人 Key 已轮换，请填写当前 Key 或更新部署配置"
      end
      end

      def self.with_channels
        Setting.transaction do
          Setting.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
          settings = Setting.find_or_create_by!(key: "notification")
          settings.lock!
          data = settings.settings.deep_dup
          data["channels"] ||= {}
          result = yield(data["channels"])
          settings.update!(settings: data) if data != settings.settings
          result
        end
      end
      def self.next_part_id(base_id, index, used_ids)
        prefix = base_id.to_s.first(80)
        candidate = "#{prefix}_#{index}"
        suffix = 2
        while used_ids.include?(candidate)
          candidate = "#{prefix}_#{index}_#{suffix}"
          suffix += 1
        end
        used_ids << candidate
        candidate
      end
      private_class_method :with_channels, :channel_for, :usable_channel, :encrypted_key, :next_part_id

      def initialize(target)
        @target = target
      end

      def send_message(message, notification:)
        row = Setting.find_by(key: "notification")&.settings&.dig("channels", @target["channel_key"])
        unless row && row["channel_type"] == "wecom_group" && row["sequence_scope"] == @target["sequence_scope"]
          raise Error, "原目标已不存在或身份不匹配，请核对原通知群"
        end
        key = ActiveRecord::Encryption.encryptor.decrypt(row.fetch("webhook_key").fetch("ciphertext"))
        identity = self.class.credential_id(key)
        raise Error, "原通知群身份不匹配" unless identity == row.fetch("credential_id", @target.fetch("channel_key"))
        raise Error, "企微群仅支持文字" unless message["type"] == "text"
        text = message.fetch("content").fetch("text")
        raise Error, "企微文字每条最多 #{MAX_TEXT_BYTES} 字节" unless text.is_a?(String) && text.bytesize.between?(1, MAX_TEXT_BYTES)
        response = Wecom::WebhookClient.new.send_message(key, text)
        code = response["errcode"]
        { "status" => code == -1 ? "unknown" : (code.zero? ? "sent" : "failed"), "response" => response,
          "error_message" => code.zero? ? nil : "企业微信拒绝（#{code}）：#{response['errmsg']}" }
      rescue ActiveRecord::Encryption::Errors::Base, KeyError
        raise Error, "原通知群凭据不可用"
      end
    end
  end
end

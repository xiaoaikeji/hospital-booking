module Notifications
  module Channels
    class WecomGroup
      MAX_TEXT_BYTES = 2048

      # 旧设置保留。每个已选机器人登记独立稳定键，之后改设置不会转发旧任务。
      def self.target(key, name: "企业微信群")
        fingerprint = credential_id(key)
        channel_key = with_channels do |channels|
          channel = channel_for(channels, fingerprint)
          next channel if channel
          raise Error, "原配置的机器人 Key 已轮换，请核对当前凭据" if channels.key?(fingerprint)
          channels[fingerprint] = { "name" => name, "channel_type" => "wecom_group",
            "sequence_scope" => fingerprint, "webhook_key" => encrypted_key(key) }
          fingerprint
        end
        { "settings_key" => "notification", "channel_key" => channel_key, "channel_type" => "wecom_group", "sequence_scope" => channel_key, "label" => name }
      end

      def self.rotate!(old_key, new_key)
        old_fingerprint = credential_id(old_key)
        new_fingerprint = credential_id(new_key)
        return if old_fingerprint == new_fingerprint
        with_channels do |channels|
          old_id = channel_for(channels, old_fingerprint)
          if old_id.nil?
            raise Error, "原配置的机器人 Key 已轮换，请核对当前凭据" if channels.key?(old_fingerprint)
            old_id = old_fingerprint
            channels[old_id] = { "name" => "企业微信群", "channel_type" => "wecom_group",
              "sequence_scope" => old_id, "webhook_key" => encrypted_key(old_key) }
          end
          other = channel_for(channels, new_fingerprint)
          if (other && other != old_id) || (channels.key?(new_fingerprint) && new_fingerprint != old_id)
            raise Error, "新 Key 已登记在其他通知群"
          end
          channels.fetch(old_id).merge!("credential_id" => new_fingerprint, "webhook_key" => encrypted_key(new_key))
        end
      end

      def self.credential_id(key)
        "wecom_#{OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, key).first(24)}"
      end

      def self.encrypted_key(key) = { "ciphertext" => ActiveRecord::Encryption.encryptor.encrypt(key) }

      def self.channel_for(channels, fingerprint)
        channels.find { |id, row| row["channel_type"] == "wecom_group" && row.fetch("credential_id", id) == fingerprint }&.first
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
      private_class_method :with_channels, :channel_for, :encrypted_key

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

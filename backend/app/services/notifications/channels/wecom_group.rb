module Notifications
  module Channels
    class WecomGroup
      # 旧设置保留。每个已选机器人登记独立稳定键，之后改设置不会转发旧任务。
      def self.target(key, name: "企业微信群")
        channel_key = "wecom_#{OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, key).first(24)}"
        Setting.transaction do
          Setting.connection.execute("SELECT pg_advisory_xact_lock(71020013)")
          row = Setting.find_or_create_by!(key: "notification")
          data = row.settings.deep_dup
          data["channels"] ||= {}
          data["channels"][channel_key] ||= { "name" => name, "channel_type" => "wecom_group",
            "sequence_scope" => channel_key, "webhook_key" => { "ciphertext" => ActiveRecord::Encryption.encryptor.encrypt(key) } }
          row.update!(settings: data)
        end
        { "settings_key" => "notification", "channel_key" => channel_key, "channel_type" => "wecom_group", "sequence_scope" => channel_key, "label" => name }
      end

      def initialize(target)
        @target = target
      end

      def send_message(message, notification:)
        row = Setting.find_by(key: "notification")&.settings&.dig("channels", @target["channel_key"])
        unless row && row["channel_type"] == "wecom_group" && row["sequence_scope"] == @target["sequence_scope"]
          raise Error, "原目标已不存在或身份不匹配，请核对原通知群"
        end
        key = ActiveRecord::Encryption.encryptor.decrypt(row.fetch("webhook_key").fetch("ciphertext"))
        identity = "wecom_#{OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, key).first(24)}"
        raise Error, "原通知群身份不匹配" unless identity == @target["channel_key"]
        raise Error, "企微群仅支持文字" unless message["type"] == "text"
        response = Wecom::WebhookClient.new.send_message(key, message.fetch("content").fetch("text"))
        code = response["errcode"]
        { "status" => code == -1 ? "unknown" : (code.zero? ? "sent" : "failed"), "response" => response,
          "error_message" => code.zero? ? nil : "企业微信拒绝（#{code}）：#{response['errmsg']}" }
      rescue ActiveRecord::Encryption::Errors::Base, KeyError
        raise Error, "原通知群凭据不可用"
      end
    end
  end
end

module Notifications
  module Channels
    class OfficialAccount
      def initialize(target)
        @target = target
      end

      def send_message(message, notification:)
        app = App.wechat_official_accounts.find_by(id: @target["app_id"], appid: @target["appid"])
        raise Error, "原公众号不存在或已取消授权" unless app&.platform_authorized?
        openid = if @target["callback_id"]
          OfficialAccountCallback.where(app: app).find(@target["callback_id"]).fields.fetch("FromUserName")
        else
          identity = UserApp.for_app(app).find(@target["user_app_id"])
          raise Error, "收件人未关注该公众号" unless identity.official_account_fan&.subscribed?
          identity.openid
        end
        content = message.fetch("content").deep_symbolize_keys
        template = message["type"] == "template"
        body = case message["type"]
        when "text" then { msgtype: "text", text: { content: content.fetch(:text) } }
        when "miniprogrampage" then { msgtype: "miniprogrampage", miniprogrampage: content }
        when "template" then content.merge(client_msg_id: "booking-#{notification.id}-#{message['id']}")
        else raise Error, "该公众号不支持此消息类型"
        end
        response = WechatPlatform::AuthorizerToken.with_token(app) do |token|
          Wechat::OfficialAccountMessageClient.new.send_message(token, body.merge(touser: openid), template: template)
        end
        receipt(response)
      rescue ActiveRecord::RecordNotFound, KeyError
        raise Error, "原公众号收件人或消息快照无效"
      rescue WechatPlatform::Error => error
        raise Error, error.message
      rescue Wechat::BaseClient::Rejected => error
        receipt("errcode" => error.code, "errmsg" => error.message)
      end
      private

      def receipt(response)
        code = response["errcode"]
        hint = code == 45015 ? "超出微信客服消息的可回复时限；" : ""
        { "status" => code == -1 ? "unknown" : (code.zero? ? "sent" : "failed"), "response" => response,
          "error_message" => code.zero? ? nil : "微信拒绝（#{code}）：#{hint}#{response['errmsg']}" }
      end
    end
  end
end

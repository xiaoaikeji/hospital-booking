module Api
  class WechatEventsController < ActionController::API
    rescue_from Wechat::MessageCrypto::Invalid, with: -> { head :forbidden }
    rescue_from Nokogiri::XML::SyntaxError, with: -> { head :bad_request }
    rescue_from Notifications::Error, WechatPlatform::Error, with: -> { head :service_unavailable }

    def create
      platform = WechatPlatform::ComponentToken.new
      raise WechatPlatform::Error if platform.missing.any?
      body = request.body.read(128.kilobytes + 1)
      return head :payload_too_large if body.bytesize > 128.kilobytes
      outer = parse_xml(body)
      plain = Wechat::MessageCrypto.new(platform.config).decrypt(outer["Encrypt"],
        timestamp: params[:timestamp], nonce: params[:nonce], signature: params[:msg_signature])
      message = parse_xml(plain)
      if params[:appid]
        auth = App.find_by(provider: "wechat", appid: params[:appid])&.app_authorization
        return head :forbidden unless auth&.authorized? && auth.original_id.present? && auth.original_id == message["ToUserName"]
        if message["MsgType"] == "event" && %w[weapp_audit_success weapp_audit_fail weapp_audit_delay].include?(message["Event"])
          audit_id = message["AuditId"].presence || message["AuditID"].presence
          if audit_id&.match?(/\A\d+\z/)
            feedback = { "type" => message["Event"], "audit_id" => audit_id, "time" => message["CreateTime"],
              "reason" => message["Reason"], "screenshots" => message["ScreenShot"] }.compact
            WechatPlatform::AuditEventWorker.perform_async(auth.app_id, feedback)
          else
            WechatPlatform::AuditEventWorker.perform_async(auth.app_id)
          end
        elsif auth.app.app_type == "official_account"
          reply = Notifications::OfficialAccountEvents.receive!(auth.app, message)
          if reply
            render xml: Wechat::MessageCrypto.new(platform.config).encrypt(reply)
            return
          end
        elsif auth.app.code_capable? && message["MsgType"] == "event" && message["Event"] == "wxa_appeal_record"
          WechatPlatform::IllegalRecordWorker.perform_async(auth.app_id) if WechatPlatform::IllegalRecords.enabled?
        elsif auth.app.code_capable? && message["MsgType"] == "event" && message["Event"] == "wxa_category_audit"
          first, second, ret, time = message.values_at("first", "second", "ret", "CreateTime")
          if [first, second, time].all? { |value| value.to_s.match?(/\A\d{1,11}\z/) } && %w[2 3].include?(ret)
            reason = (message["reason"].presence || message["Reason"].presence)&.first(2000) if ret == "2"
            WechatPlatform::CategoryAuditEventWorker.perform_async(auth.app_id, first, second, ret, time, reason)
          end
        end
      else
        return head :forbidden unless message["AppId"] == platform.config[:appid]
        case message["InfoType"]
        when "component_verify_ticket"
          return head :bad_request if message["ComponentVerifyTicket"].blank?
          platform.store_ticket(message["ComponentVerifyTicket"])
        when "unauthorized", "updateauthorized"
          auth = App.find_by(provider: "wechat", appid: message["AuthorizerAppid"])&.app_authorization
          if auth
            at = Time.zone.at(Integer(message["CreateTime"].to_s, exception: false) || 0)
            auth.with_lock do
              next if auth.event_at && at.to_i < auth.event_at.to_i
              if message["InfoType"] == "unauthorized"
                auth.update!(refresh_token: nil, scopes: [], event_at: at, revoked_at: at, state_digest: nil)
              elsif auth.authorized? && (!auth.event_at || at.to_i > auth.event_at.to_i)
                info = platform.with_token { |token| platform.client.authorization(token, platform.config[:appid], message["AuthorizationCode"]) }
                attributes = WechatPlatform::AuthorizationFlow.authorization_attributes(info, auth.app)
                auth.update!(attributes.merge(event_at: at))
              end
            end
          end
        end
      end
      render plain: "success"
    end

    private

    def parse_xml(body)
      doc = Nokogiri::XML(body) { |options| options.strict.nonet }
      raise Wechat::MessageCrypto::Invalid if doc.internal_subset || doc.root&.name != "xml"
      doc.root.element_children.to_h { |child| [ child.name, child.text ] }
    end
  end
end

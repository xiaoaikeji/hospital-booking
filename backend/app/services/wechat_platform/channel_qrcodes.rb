module WechatPlatform
  class ChannelQrcodes
    def initialize(app, actor:, request: nil)
      @app, @actor, @request = app, actor, request
      @verifier = Rails.application.message_verifier("wechat.channel_qrcode")
    end

    def form_key
      @verifier.generate("qd_#{SecureRandom.alphanumeric(12)}", purpose: purpose)
    end

    def create!(row, key)
      raise Error, "需要超级管理员权限" unless @actor.super_admin?
      scene = @verifier.verified(key.to_s, purpose: purpose)
      raise Error, "表单已失效，请重新打开展示该公众号的新增页" unless scene
      row.scene = scene
      row.validate!(:form)
      raise Error, "请先完成本公众号的平台授权" unless @app.platform_authorized?
      # 换发令牌先提交。重复表单即使并发到达，也只会登记同一个渠道。
      AuthorizerToken.with_token(@app) do |token|
        @app.with_lock do
          raise Error, "请先完成本公众号的平台授权" unless @app.platform_authorized?
          saved = OfficialAccountQrcode.find_by(app: @app, scene: scene)
          if saved
            raise Error, "此表单已生成其他名称的渠道码，请重新打开新增页" if saved.name != row.name
            return saved
          end
          row.update!(Wechat::ChannelQrcodeClient.new.create(token, scene))
          audit("success", channel_id: row.id)
          row
        end
      end
    rescue ActiveRecord::RecordInvalid, Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      audit("failed", reason: error.is_a?(ActiveRecord::RecordInvalid) ? "渠道码资料无效" : error.message)
      raise
    end

    private

    def purpose = "app/#{@app.id}/admin/#{@actor.id}"

    def audit(status, **details)
      WechatPlatform.log!(@app, "channel_qrcode_create", actor: @actor, request: @request, status: status, details: details)
    end
  end
end

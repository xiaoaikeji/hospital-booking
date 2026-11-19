module WechatPlatform
  class ReleaseQrcode
    def self.fetch(app)
      Rails.cache.fetch("apps/#{app.id}/wechat/release_home_qrcode", expires_in: 30.days) do
        managed = app.app_authorization&.authorized?
        token = if managed
          AuthorizerToken.fetch(app)
        else
          secret, = AppConfiguration.new(app).credential
          raise Error, "请在应用编辑页配置本应用的 AppSecret，或先完成微信授权。" if secret.blank?
          Wechat::CredentialClient.new.access_token(app.appid, secret)
        end
        Wechat::MiniProgramQrcodeClient.new.released_homepage(token)
      rescue Wechat::BaseClient::Rejected => error
        AuthorizerToken.expire(app, token) if managed && token && error.invalid_token?
        raise Error, "微信找不到正式版首页，请确认此小程序已发布正式版（41030）。" if error.code == 41030
        raise
      end
    end
  end
end

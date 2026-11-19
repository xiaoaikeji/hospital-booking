module WechatPlatform
  class ReleaseQrcode
    def self.release_key(app) = "apps/#{app.id}/wechat/release_home_qrcode"
    def self.trial_key(trial) = "apps/#{trial.app_id}/wechat/trial_qrcode/#{trial.cache_key_with_version}"

    def self.clear(app, trial)
      Rails.cache.delete(release_key(app))
      Rails.cache.delete(trial_key(trial)) if trial
    end

    def self.fetch(app)
      if app.app_type == "official_account"
        raise Error, "请先完成此公众号的平台授权" unless app.platform_authorized?
        return Rails.cache.fetch("apps/#{app.id}/wechat/official_account_qrcode", expires_in: 30.days) do
          platform = ComponentToken.new
          info = platform.with_token { |token| platform.client.authorizer_info(token, platform.config[:appid], app.appid) }
          Wechat::OfficialAccountQrcodeClient.new.fetch(info)
        end
      end

      Rails.cache.fetch(release_key(app), expires_in: 30.days) do
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

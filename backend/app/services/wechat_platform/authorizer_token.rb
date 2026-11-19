module WechatPlatform
  class AuthorizerToken
    def self.expire(app, token)
      key = "apps/#{app.id}/channel_token"
      app.app_authorization.with_lock { Rails.cache.delete(key) if Rails.cache.read(key)&.fetch(:value) == token }
    end

    def self.fetch(app)
      auth = app.app_authorization
      raise Error, "请先完成该小程序的微信授权" unless app.provider == "wechat" && auth
      auth.with_lock do
        raise Error, "授权已取消，请重新授权" unless auth.authorized?
        key = "apps/#{app.id}/channel_token"
        cached = Rails.cache.read(key)
        return cached[:value] if cached && cached[:revision] == auth.updated_at.to_f
        platform = ComponentToken.new
        data = platform.with_token { |token| platform.client.refresh(token, platform.config[:appid], app.appid, auth.refresh_token) }
        token = data["authorizer_access_token"].presence || raise(HttpConnection::Unavailable, "微信未返回授权方令牌")
        auth.update!(refresh_token: data["authorizer_refresh_token"]) if data["authorizer_refresh_token"].present?
        revision = auth.updated_at.to_f
        ActiveRecord.after_all_transactions_commit do
          Rails.cache.write(key, { value: token, revision: revision }, expires_in: [ data["expires_in"].to_i - 300, 1 ].max.seconds)
        end
        token
      end
    end
  end
end

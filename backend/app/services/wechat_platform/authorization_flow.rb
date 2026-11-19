module WechatPlatform
  class AuthorizationFlow
    def initialize(app, platform: ComponentToken.new)
      @app, @platform = app, platform
    end

    def start!(admin, request)
      raise Error, "仅微信小程序支持授权" unless @app.provider == "wechat"
      code = @platform.with_token { |token| @platform.client.pre_auth(token, @platform.config[:appid]) }
      state = SecureRandom.urlsafe_base64(32)
      @app.with_lock do
        auth = @app.app_authorization || @app.build_app_authorization
        auth.update!(initiator: admin, state_digest: Digest::SHA256.hexdigest(state), state_expires_at: 10.minutes.from_now)
        WechatPlatform.log!(@app, "authorize", actor: admin, request: request)
      end
      callback = yield(state)
      query = { component_appid: @platform.config[:appid], pre_auth_code: code, biz_appid: @app.appid, auth_type: 2, redirect_uri: callback }
      "https://mp.weixin.qq.com/cgi-bin/componentloginpage?#{query.to_query}"
    end

    def self.authorization_attributes(info, app)
      raise Error, "微信授权 AppID 与目标应用不符" unless info.is_a?(Hash) && info["authorizer_appid"] == app.appid
      refresh = info["authorizer_refresh_token"].presence || raise(Error, "微信未返回刷新令牌")
      { refresh_token: refresh, scopes: Array(info["func_info"]).filter_map { |item| item.dig("funcscope_category", "id") } }
    end

    def complete!(state, code, admin, request)
      auth = @app.app_authorization
      raise Error, "授权请求已失效" unless auth && state.present? && code.present?
      consumed_at = auth.with_lock do
        valid = auth.initiator_id == admin.id && auth.state_expires_at&.future? &&
          ActiveSupport::SecurityUtils.secure_compare(auth.state_digest.to_s, Digest::SHA256.hexdigest(state))
        raise Error, "授权请求已失效" unless valid
        auth.update!(state_digest: nil, state_expires_at: nil)
        auth.updated_at
      end
      auth.with_lock do
        raise Error, "授权状态已变化，请重新发起" unless auth.updated_at == consumed_at
        info = @platform.with_token { |token| @platform.client.authorization(token, @platform.config[:appid], code) }
        attributes = self.class.authorization_attributes(info, @app)
        original = @platform.with_token { |token| @platform.client.original_id(token, @platform.config[:appid], @app.appid) }
        auth.update!(attributes.merge(original_id: original, event_at: Time.current))
        WechatPlatform.log!(@app, "authorized", actor: admin, request: request)
      end
    end
  end
end

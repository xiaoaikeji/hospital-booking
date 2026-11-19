module WechatPlatform
  class AuthorizationFlow
    def initialize(app, platform: ComponentToken.new)
      @app, @platform = app, platform
    end

    def start!(admin, request)
      raise Error, "此平台尚未接入平台授权" unless @app.provider == "wechat"
      code = @platform.with_token { |token| @platform.client.pre_auth(token, @platform.config[:appid]) }
      state = SecureRandom.urlsafe_base64(32)
      request.session[:wechat_authorization_session] ||= request.session.id&.to_s || SecureRandom.hex(32)
      @app.with_lock do
        auth = @app.app_authorization || @app.build_app_authorization
        auth.update!(initiator: admin, state_digest: self.class.session_digest(state, request), state_expires_at: 10.minutes.from_now)
        WechatPlatform.log!(@app, "authorize", actor: admin, request: request)
      end
      callback = yield(state)
      query = { component_appid: @platform.config[:appid], pre_auth_code: code, biz_appid: @app.appid, auth_type: (@app.code_capable? ? 2 : 1), redirect_uri: callback }
      "https://mp.weixin.qq.com/cgi-bin/componentloginpage?#{query.to_query}"
    end

    def self.session_digest(state, request)
      Digest::SHA256.hexdigest("#{request.session[:wechat_authorization_session]}:#{state}")
    end

    def self.pending!(state, admin, request)
      raise Error, "授权请求已失效" unless state.is_a?(String) && state.present?
      pending = AppAuthorization.where(initiator: admin).where("state_expires_at > ?", Time.current)
      auth = pending.find_by(state_digest: session_digest(state, request))
      # 升级前已打开的授权页，沿用原会话内的应用 ID 和摘要，直至十分钟有效期结束。
      if !auth && request.session[:wechat_app_id]
        auth = pending.find_by(app_id: request.session[:wechat_app_id], state_digest: Digest::SHA256.hexdigest(state))
      end
      auth || raise(Error, "授权请求已失效")
    end

    def self.authorization_attributes(info, app)
      raise Error, "微信授权 AppID 与目标应用不符" unless info.is_a?(Hash) && info["authorizer_appid"] == app.appid
      refresh = info["authorizer_refresh_token"].presence || raise(Error, "微信未返回刷新令牌")
      { refresh_token: refresh, scopes: Array(info["func_info"]).filter_map { |item| item.dig("funcscope_category", "id") } }
    end

    def complete!(auth, code, admin, request)
      raise Error, "授权请求已失效" if code.blank?
      expected_digest = auth.state_digest
      consumed_at = auth.with_lock do
        valid = auth.initiator_id == admin.id && auth.state_expires_at&.future? &&
          ActiveSupport::SecurityUtils.secure_compare(auth.state_digest.to_s, expected_digest)
        raise Error, "授权请求已失效" unless valid
        auth.update!(state_digest: nil, state_expires_at: nil)
        auth.updated_at
      end
      auth.with_lock do
        raise Error, "授权状态已变化，请重新发起" unless auth.updated_at == consumed_at
        info = @platform.with_token { |token| @platform.client.authorization(token, @platform.config[:appid], code) }
        attributes = self.class.authorization_attributes(info, @app)
        original = @platform.with_token { |token| @platform.client.original_id(token, @platform.config[:appid], @app.appid) }
        at = Time.current
        auth.update!(attributes.merge(original_id: original, event_at: at, authorized_at: at))
        WechatPlatform.log!(@app, "authorized", actor: admin, request: request)
      end
    end
  end
end

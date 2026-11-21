class MiniProgramLogin
  class Disabled < StandardError; end
  class AccountDisabled < StandardError; end
  class IdentityConflict < StandardError; end

  def initialize(app)
    @app = app
  end

  def call(code, scene: nil)
    secret = Wechat::AccessToken.credential!(@app)
    openid, unionid = Wechat::MiniProgramLoginClient.new.identity(@app.appid, secret, code)
    attempts = 0
    begin
      attempts += 1
      UserApp.transaction(requires_new: true) do
        @app.lock!("FOR SHARE")
        raise Disabled unless @app.accessible?
        raise Wechat::Error, "应用凭据已变更，请重新登录" unless Wechat::AccessToken.credential!(@app) == secret

        peers = unionid && trusted_appids
        lock_unionid!(unionid) if peers
        bindings = UserApp.for_app(@app)
        identity = bindings.lock.find_by(openid: openid)
        unless identity
          user = shared_user(peers, unionid) if peers
          raise IdentityConflict if user && bindings.exists?(user_id: user.id)
          identity = bindings.create!(app: @app, user: user || User.create!(platform: @app.provider), openid: openid)
        end
        user = identity.user.lock!
        self.class.check_account!(identity, user)
        now = Time.current
        identity.update!(unionid: identity.unionid.presence || unionid, last_sign_in_at: now, sign_in_count: identity.sign_in_count + 1)
        user.update!(last_login_at: now)
        self.class.record_scene(identity, scene)
        MiniProgramSession.issue!(identity)
      end
    rescue ActiveRecord::RecordNotUnique
      # The losing first login (or a colliding public user number) rolls back its whole transaction.
      retry if attempts < 3
      raise IdentityConflict, cause: nil
    end
  end

  def self.check_account!(identity, user)
    raise AccountDisabled unless identity.status == "active" && user.status == "active" && user.platform == identity.provider
  end

  def self.record_scene(identity, scene)
    return unless scene.is_a?(String) && scene.present? && scene.length <= 128 && !scene.match?(/[[:cntrl:]]/)
    Log.record!(source: "user", category: "mini_program", action: "mini_program.entry", actor: identity.user,
      target: identity, details: { scene: scene })
  end

  private

  # Each group is confirmed by the hospital against its current WeChat Open Platform account.
  def trusted_appids
    groups = Setting.find_by(key: "wechat")&.settings&.fetch("unionid_app_groups", nil)
    return unless groups.is_a?(Array) && groups.all? { |group| group.is_a?(Array) && group.all?(String) }
    return unless groups.flatten.uniq.size == groups.flatten.size
    groups.find { |group| group.include?(@app.appid) }
  end

  def lock_unionid!(unionid)
    # A new binding in either app must see the other transaction's committed identity.
    key = Digest::SHA256.digest("booking.wechat.unionid.#{unionid}").unpack1("q>")
    UserApp.connection_pool.with_connection { |connection| connection.execute("SELECT pg_advisory_xact_lock(#{key})") }
  end

  def shared_user(peers, unionid)
    ids = UserApp.where(provider: @app.provider, appid: peers, unionid: unionid)
      .joins(:app).where(apps: { app_type: "mini_program" }).distinct.limit(2).pluck(:user_id)
    raise IdentityConflict if ids.size > 1
    User.find(ids.first) if ids.any?
  end
end

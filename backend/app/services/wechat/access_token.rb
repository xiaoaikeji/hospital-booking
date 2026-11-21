module Wechat
  class AccessToken
    def self.with_token(app)
      access = new(app)
      token = access.fetch
      yield token
    rescue BaseClient::Rejected => error
      access.expire(token) if token && error.invalid_token?
      raise
    end

    def self.configured?(app)
      app&.provider == "wechat" && app.accessible? && AppConfiguration.new(app).credential.first.present?
    rescue AppConfiguration::Invalid
      false
    end

    def self.credential!(app)
      raise Error, "此微信应用已停用或不存在" unless app&.provider == "wechat" && app.accessible?

      AppConfiguration.new(app).credential.first.presence || raise(Error, "请在应用编辑页配置本账号的 AppSecret")
    rescue AppConfiguration::Invalid => error
      raise Error, error.message, cause: nil
    end

    def self.cache_prefix(app, secret)
      revision = AppConfiguration.new(app).digest([app.appid, secret])
      "apps/#{app.id}/wechat/direct/#{revision}"
    end

    def self.store(app, secret, result, unless_exist: false)
      token = result.fetch("access_token")
      key = "#{cache_prefix(app, secret)}/access_token"
      Rails.cache.write(key, token, expires_in: [result.fetch("expires_in") - 60, 1].max.seconds, unless_exist: unless_exist)
      token
    end

    def initialize(app)
      @app = app
    end

    def fetch
      raise Error, "此微信应用不存在" unless @app

      @app.reload
      secret = self.class.credential!(@app)
      @used_key = token_key(secret)
      cached = Rails.cache.read(@used_key)
      return cached if cached

      @app.with_lock do
        secret = self.class.credential!(@app)
        @used_key = token_key(secret)
        Rails.cache.read(@used_key) || request_token(secret, @used_key)
      end
    end

    def expire(token)
      @app.with_lock do
        next unless Rails.cache.read(@used_key) == token

        Rails.cache.delete(@used_key)
        Rails.cache.write("#{@used_key}/rejected", true, expires_in: 5.minutes)
      end
    end

    private

    def token_key(secret) = "#{self.class.cache_prefix(@app, secret)}/access_token"

    def request_token(secret, key)
      rejected = "#{key}/rejected"
      # WeChat rate-limits forced refreshes for each AppID. Business requests are never replayed here.
      force = Rails.cache.read(rejected) && Rails.cache.write("apps/#{@app.id}/wechat/forced_refresh", true,
        unless_exist: true, expires_in: 30.seconds)
      result = CredentialClient.new.access_token(@app.appid, secret, force_refresh: !!force)
      token = self.class.store(@app, secret, result)
      Rails.cache.delete(rejected) if force
      token
    end
  end
end

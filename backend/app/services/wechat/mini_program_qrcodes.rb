module Wechat
  class MiniProgramQrcodes
    VERSIONS = %w[release trial].freeze

    def self.fetch(app, version)
      raise Error, "请选择正式版或体验版" unless VERSIONS.include?(version)

      Rails.cache.fetch(cache_key(app, version), expires_in: 30.days) do
        AccessToken.with_token(app) { |token| MiniProgramQrcodeClient.new.homepage(token, version: version) }
      end
    rescue BaseClient::Rejected => error
      if error.code == 41030
        label = version == "release" ? "正式版" : "体验版"
        raise Error, "微信找不到#{label}首页，请在微信公众平台核对版本（41030）。"
      end
      raise
    end

    def self.clear(app)
      VERSIONS.each { |version| Rails.cache.delete(cache_key(app, version)) }
    end

    def self.cache_key(app, version)
      raise Error, "请选择微信小程序" unless app.code_capable?

      prefix = AccessToken.cache_prefix(app, AccessToken.credential!(app))
      "#{prefix}/home_qrcode/#{version}"
    end
    private_class_method :cache_key
  end
end

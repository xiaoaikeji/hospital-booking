module Wechat
  class MiniProgramLoginClient < BaseClient
    Identity = Data.define(:openid, :unionid, :credential_revision)
    class MissingCode < StandardError; end

    def identity(app, code)
      validate_code!(code)
      secret = AccessToken.credential!(app)
      result = json(:get, "/sns/jscode2session", query: {
        appid: app.appid, secret: secret, js_code: code, grant_type: "authorization_code"
      })
      openid = identifier(result["openid"])
      raise HttpConnection::Unavailable, "微信未返回有效的 OpenID" unless openid

      Identity.new(openid, identifier(result["unionid"]), AppConfiguration.new(app).digest(secret))
    end

    # Called under the application lock, after exchanging the short-lived login code.
    def check_credentials!(app, identity)
      current = AppConfiguration.new(app).digest(AccessToken.credential!(app))
      raise Error, "应用凭据已变更，请重新登录" unless identity.credential_revision == current
    end

    def phone_number(app, code)
      validate_code!(code)
      result = AccessToken.with_token(app) do |token|
        json(:post, "/wxa/business/getuserphonenumber", query: { access_token: token }, body: { code: code })
      end
      info = result["phone_info"]
      unless info.is_a?(Hash) && info["watermark"].is_a?(Hash) && info["watermark"]["appid"] == app.appid
        raise HttpConnection::Unavailable, "微信未返回本应用的手机号"
      end
      number, country = info.values_at("purePhoneNumber", "countryCode")
      country = country.to_s.strip
      unless number.is_a?(String) && country.match?(/\A[1-9]\d{0,2}\z/) &&
          number.match?(/\A\d{4,14}\z/) && (country + number).length <= 15
        raise HttpConnection::Unavailable, "微信未返回有效手机号"
      end
      return "+#{country}#{number}" unless country == "86"
      raise HttpConnection::Unavailable, "微信未返回有效手机号" unless number.match?(/\A1\d{10}\z/)
      number
    end

    private

    def validate_code!(code)
      raise MissingCode, "缺少有效微信凭证" unless code.is_a?(String) && code.bytesize.between?(1, 512) && !code.match?(/[[:space:][:cntrl:]]/)
    end

    def identifier(value)
      value if value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_-]{1,150}\z/)
    end
  end
end

module Wechat
  class MiniProgramLoginClient < BaseClient
    def identity(appid, secret, code)
      result = json(:get, "/sns/jscode2session", query: {
        appid: appid, secret: secret, js_code: code, grant_type: "authorization_code"
      })
      openid = identifier(result["openid"])
      raise HttpConnection::Unavailable, "微信未返回有效的 OpenID" unless openid

      [ openid, identifier(result["unionid"]) ]
    end

    def phone_number(appid, token, code)
      result = json(:post, "/wxa/business/getuserphonenumber", query: { access_token: token }, body: { code: code })
      info = result["phone_info"]
      unless info.is_a?(Hash) && info["watermark"].is_a?(Hash) && info["watermark"]["appid"] == appid
        raise HttpConnection::Unavailable, "微信未返回本应用的手机号"
      end
      number, country = info.values_at("purePhoneNumber", "countryCode")
      unless number.is_a?(String) && country.is_a?(String) && country.match?(/\A[1-9]\d{0,2}\z/) &&
          number.match?(/\A\d{4,14}\z/) && (country + number).length <= 15
        raise HttpConnection::Unavailable, "微信未返回有效手机号"
      end
      return "+#{country}#{number}" unless country == "86"
      raise HttpConnection::Unavailable, "微信未返回有效手机号" unless number.match?(/\A1\d{10}\z/)
      number
    end

    private

    def identifier(value)
      value if value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_-]{1,150}\z/)
    end
  end
end

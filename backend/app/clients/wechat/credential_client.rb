module Wechat
  class CredentialClient < BaseClient
    def access_token(appid, secret, force_refresh: false)
      body = { grant_type: "client_credential", appid: appid, secret: secret }
      body[:force_refresh] = true if force_refresh
      result = json(:post, "/cgi-bin/stable_token", body: body)
      token = required(result, "access_token")
      raise HttpConnection::Unavailable, "微信未返回有效令牌" unless token.is_a?(String)
      seconds = Integer(result["expires_in"].to_s, exception: false)
      raise HttpConnection::Unavailable, "微信未返回有效的令牌有效期" unless seconds&.positive?

      result.merge("expires_in" => seconds)
    rescue Rejected => error
      raise HttpConnection::Unavailable, "微信平台暂不可达" if error.code == -1
      raise
    end
    alias_method :verify!, :access_token
  end
end

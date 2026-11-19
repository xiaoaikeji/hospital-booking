module Wechat
  class CredentialClient < BaseClient
    def verify!(appid, secret)
      result = json(:post, "/cgi-bin/stable_token", body: { grant_type: "client_credential", appid: appid, secret: secret })
      required(result, "access_token")
    rescue Rejected => error
      raise HttpConnection::Unavailable, "微信平台暂不可达" if error.code == -1
      raise
    end
  end
end

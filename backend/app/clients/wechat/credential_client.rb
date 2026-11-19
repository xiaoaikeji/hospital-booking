module Wechat
  class CredentialClient < BaseClient
    def verify!(appid, secret)
      result = json(:post, "/cgi-bin/stable_token", body: { grant_type: "client_credential", appid: appid, secret: secret })
      required(result, "access_token")
    end
  end
end

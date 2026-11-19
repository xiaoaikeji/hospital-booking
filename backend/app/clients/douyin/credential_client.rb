module Douyin
  class CredentialClient
    def verify!(appid, secret)
      connection = HttpConnection.build("https://developer.toutiao.com")
      response = HttpConnection.request(connection, :post, "/api/apps/v2/token",
        body: { grant_type: "client_credential", appid: appid, secret: secret })
      result = HttpConnection.json(response)
      code = Integer(result["err_no"].to_s, exception: false)
      raise HttpConnection::Unavailable, "平台暂不可达或响应无效" unless code && code != -1
      raise AppConfiguration::Invalid, "抖音凭据校验失败（#{code}）" unless code.zero?
      result.dig("data", "access_token").presence || raise(HttpConnection::Unavailable, "平台响应无效")
    end
  end
end

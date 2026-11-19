module Wechat
  class MiniProgramQrcodeClient < BaseClient
    def released_homepage(token)
      response = HttpConnection.request(@connection, :post, "/wxa/getwxacodeunlimit",
        query: { access_token: token }, body: { scene: "home", env_version: "release", check_path: true, width: 430 })
      bytes = response.body.to_s.b
      return bytes if bytes.start_with?("\x89PNG\r\n\x1a\n".b, "\xff\xd8\xff".b)

      checked(HttpConnection.json(response))
      raise HttpConnection::Unavailable, "微信未返回正式版小程序码"
    end
  end
end

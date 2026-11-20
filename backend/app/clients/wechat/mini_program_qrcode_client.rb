module Wechat
  class MiniProgramQrcodeClient < BaseClient
    # 有限码允许页面自带 query，沿用正式版页面校验，不要求调用方改成 scene 参数。
    def page(token, path:)
      response = HttpConnection.request(@connection, :post, "/wxa/getwxacode",
        query: { access_token: token }, body: { path: path, env_version: "release", width: 1280 })
      bytes = response.body.to_s.b
      return bytes if bytes.start_with?("\x89PNG\r\n\x1a\n".b, "\xff\xd8\xff".b)
      checked(HttpConnection.json(response))
      raise HttpConnection::Unavailable, "微信未返回小程序页面码，请重试"
    end

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

module Wechat
  class MiniProgramQrcodeClient < BaseClient
    # 有限码允许页面自带 query，沿用正式版页面校验。
    def page(token, path:)
      code("/wxa/getwxacode", token, { path: path, env_version: "release", width: 1280 })
    end

    def homepage(token, version:)
      code("/wxa/getwxacodeunlimit", token, { scene: "home", env_version: version, check_path: version == "release", width: 430 })
    end

    private

    def code(path, token, body)
      response = HttpConnection.request(@connection, :post, path, query: { access_token: token }, body: body)
      bytes = response.body.to_s.b
      return bytes if bytes.start_with?("\x89PNG\r\n\x1a\n".b, "\xff\xd8\xff".b)

      checked(HttpConnection.json(response))
      raise HttpConnection::Unavailable, "微信未返回小程序码图片"
    end
  end
end

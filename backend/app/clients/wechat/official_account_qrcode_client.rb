module Wechat
  class OfficialAccountQrcodeClient
    def fetch(info)
      primary = info["qrcode_url"].presence
      if primary
        begin
          return download(primary)
        rescue HttpConnection::Unavailable
          raise unless info["user_name"].to_s.start_with?("gh_")
        end
      end
      username = info["user_name"].to_s
      raise HttpConnection::Unavailable, "微信未返回此公众号的二维码" unless username.start_with?("gh_")
      download("https://open.weixin.qq.com/qr/code?#{URI.encode_www_form(username: username)}")
    end

    private

    def download(url)
      uri = URI.parse(url)
      host = uri.host.to_s.downcase
      allowed = %w[qpic.cn qlogo.cn open.weixin.qq.com].include?(host) || host.end_with?(".qpic.cn", ".qlogo.cn")
      unless uri.is_a?(URI::HTTP) && uri.port == uri.default_port && !uri.userinfo && allowed
        raise HttpConnection::Unavailable, "微信返回的公众号二维码地址无效"
      end
      # 微信有时返回 HTTP 图地址。只用 HTTPS 访问指定的微信图片主机。
      connection = HttpConnection.build("https://#{host}")
      response = HttpConnection.request(connection, :get, uri.path.presence || "/", query: URI.decode_www_form(uri.query.to_s).to_h)
      bytes = response.body.to_s.b
      return bytes if bytes.start_with?("\x89PNG\r\n\x1a\n".b, "\xff\xd8\xff".b)
      raise HttpConnection::Unavailable, "微信未返回公众号二维码图片"
    rescue URI::InvalidURIError, ArgumentError
      raise HttpConnection::Unavailable, "微信返回的公众号二维码地址无效", cause: nil
    end
  end
end

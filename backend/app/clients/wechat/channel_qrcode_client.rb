module Wechat
  class ChannelQrcodeClient < BaseClient
    def create(token, scene)
      data = json(:post, "/cgi-bin/qrcode/create", query: { access_token: token },
        body: { action_name: "QR_LIMIT_STR_SCENE", action_info: { scene: { scene_str: scene } } })
      ticket, url = data.values_at("ticket", "url")
      uri = URI.parse(url) if url.is_a?(String) && url.bytesize <= 512
      unless ticket.is_a?(String) && ticket.present? && uri.is_a?(URI::HTTP) && uri.host.present? &&
          !uri.userinfo && uri.port == uri.default_port && (uri.host == "weixin.qq.com" || uri.host.end_with?(".weixin.qq.com")) &&
          uri.path.present? && (data["expire_seconds"].nil? || data["expire_seconds"].to_s == "0")
        raise HttpConnection::Unavailable, "微信未返回完整的永久渠道码，请在此表单重试"
      end
      { ticket: ticket, url: url }
    rescue URI::InvalidURIError
      raise HttpConnection::Unavailable, "微信返回的渠道码地址无效，请在此表单重试"
    end
  end
end

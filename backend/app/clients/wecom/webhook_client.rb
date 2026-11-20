module Wecom
  class WebhookClient
    def send_text(key, message) = send_message(key, message).fetch("errcode")

    def send_message(key, message)
      connection = HttpConnection.build("https://qyapi.weixin.qq.com")
      response = HttpConnection.request(connection, :post, "/cgi-bin/webhook/send", query: { key: key },
        body: { msgtype: "text", text: { content: message.byteslice(0, 2048).scrub("") } })
      data = HttpConnection.json(response)
      code = Integer(data["errcode"].to_s, 10, exception: false)
      raise HttpConnection::Unavailable, "企业微信未确认发送结果" unless code
      { "errcode" => code, "errmsg" => data["errmsg"].to_s.gsub(key, "[已过滤]").first(300) }
    end
  end
end

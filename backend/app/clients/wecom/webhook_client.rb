module Wecom
  class WebhookClient
    def send_text(key, message)
      connection = HttpConnection.build("https://qyapi.weixin.qq.com")
      text = message.byteslice(0, 2048).scrub("")
      response = HttpConnection.request(connection, :post, "/cgi-bin/webhook/send", query: { key: key },
        body: { msgtype: "text", text: { content: text } })
      code = Integer(HttpConnection.json(response)["errcode"].to_s, 10, exception: false)
      raise HttpConnection::Unavailable, "企业微信未确认发送结果" unless code
      code
    end
  end
end

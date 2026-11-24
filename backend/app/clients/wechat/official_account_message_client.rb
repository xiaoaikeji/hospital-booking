module Wechat
  class OfficialAccountMessageClient < BaseClient
    def templates(token)
      rows = json(:get, "/cgi-bin/template/get_all_private_template", query: { access_token: token })["template_list"]
      raise HttpConnection::Unavailable, "微信模板列表无效" unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row["template_id"].present? && row["content"].is_a?(String) }
      rows
    end

    def send_message(token, body, template: false)
      path = template ? "/cgi-bin/message/template/send" : "/cgi-bin/message/custom/send"
      response = HttpConnection.request(@connection, :post, path, query: { access_token: token }, body: body)
      data = HttpConnection.json(response)
      code = Integer(data["errcode"].to_s, exception: false)
      raise HttpConnection::Unavailable, "微信未确认发送结果" unless code
      raise Rejected, code if [ 40001, 40014, 42001 ].include?(code)
      { "errcode" => code, "msgid" => Integer(data["msgid"].to_s, 10, exception: false) }.compact
    end
  end
end

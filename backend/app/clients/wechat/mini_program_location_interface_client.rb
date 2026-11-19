module Wechat
  class MiniProgramLocationInterfaceClient < MiniProgramSettingsClient
    def list
      data = json(:get, "/wxa/security/get_privacy_interface", query: @query)
      rows = data.fetch("interface_list") { [] if data["errcode"] == 0 }
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row["api_name"].is_a?(String) && row["api_name"].length.between?(1, 100) }
        raise HttpConnection::Unavailable, "微信返回的地理位置接口列表不完整，请重新读取"
      end
      rows
    end

    def apply(api_name, content, pictures)
      body = { api_name: api_name, content: content }
      body[:pic_list] = pictures if pictures.any?
      result = json(:post, "/wxa/security/apply_privacy_interface", query: @query, body: body)
      id = result["audit_id"].to_s
      raise HttpConnection::Unavailable, "微信未返回有效申请单号" unless id.match?(/\A[1-9]\d*\z/)
      id
    end
  end
end

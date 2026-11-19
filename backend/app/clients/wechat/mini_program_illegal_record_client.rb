module Wechat
  class MiniProgramIllegalRecordClient < MiniProgramSettingsClient
    def violations(now)
      records("/wxa/getillegalrecords", start_time: (now - 7.days).to_i, end_time: now.to_i)
    end

    def appeals(number)
      records("/wxa/getappealrecords", illegal_record_id: number)
    end

    private

    def records(path, body)
      data = json(:post, path, query: @query, body: body)
      rows = data.fetch("records") { [] if data["errcode"] == 0 }
      raise HttpConnection::Unavailable, "微信返回的违规或申诉名单不完整" unless rows.is_a?(Array) && rows.all?(Hash)
      rows
    end
  end
end

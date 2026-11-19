module Wechat
  class MiniProgramProfileClient < MiniProgramSettingsClient
    def basic_info
      data = json(:post, "/cgi-bin/account/getaccountbasicinfo", query: @query, body: {})
      groups = data.slice("nickname_info", "signature_info", "head_image_info")
      unless groups.values.all?(Hash) && (groups.any? || data["nickname"].is_a?(String))
        raise HttpConnection::Unavailable, "微信返回的账号资料不完整，请重新读取"
      end
      data.slice("appid", "nickname").merge(groups)
    end

    def check_nickname(nickname)
      data = json(:post, "/cgi-bin/wxverify/checkwxverifynickname", query: @query, body: { nick_name: nickname })
      unless [true, false].include?(data["hit_condition"])
        raise HttpConnection::Unavailable, "微信未返回名称检测结果，请重新检测"
      end
      data.slice("hit_condition", "wording")
    end

    def modify_signature(signature)
      write("/cgi-bin/account/modifysignature", signature: signature)
    end

    def modify_head_image(media_id)
      write("/cgi-bin/account/modifyheadimage", head_img_media_id: media_id, x1: "0", y1: "0", x2: "1", y2: "1")
    end

    private

    def write(path, body)
      result = json(:post, path, query: @query, body: body)
      raise HttpConnection::Unavailable unless result.key?("errcode")
    rescue HttpConnection::Unavailable
      raise HttpConnection::Unavailable, "微信尚未确认修改结果，请重新读取账号资料，核实后再操作"
    end
  end
end

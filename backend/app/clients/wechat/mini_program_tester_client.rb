module Wechat
  class MiniProgramTesterClient < BaseClient
    def list(token)
      members = json(:post, "/wxa/memberauth", query: { access_token: token }, body: { action: "get_experiencer" }).fetch("members", [])
      unless members.is_a?(Array) && members.all? { |entry| entry.is_a?(Hash) && entry["userstr"].is_a?(String) && entry["userstr"].present? }
        raise HttpConnection::Unavailable, "微信返回的体验者名单无效，请重新读取"
      end
      members.pluck("userstr").uniq
    end

    def bind(token, wechatid)
      result = json(:post, "/wxa/bind_tester", query: { access_token: token }, body: { wechatid: wechatid })
      unless result["userstr"].present? || result["errcode"].to_s == "0"
        raise HttpConnection::Unavailable, "微信未确认绑定结果，请核对体验者名单"
      end
    end

    def unbind(token, userstr)
      result = json(:post, "/wxa/unbind_tester", query: { access_token: token }, body: { userstr: userstr })
      raise HttpConnection::Unavailable, "微信未确认解绑结果，请核对体验者名单" unless result["errcode"].to_s == "0"
    end
  end
end

module Wechat
  class OpenPlatformClient < BaseClient
    def bound_appid(appid, token)
      data = call("get", token, appid: appid)
      open_appid(data, appid)
    rescue Rejected => error
      raise unless error.code == 89002
      nil
    end

    def create(appid, token)
      open_appid(call("create", token, appid: appid), appid)
    end

    def bind(appid, account, token)
      confirm(call("bind", token, appid: appid, open_appid: account), appid, account)
    end

    def unbind(appid, account, token)
      confirm(call("unbind", token, appid: appid, open_appid: account), appid, account)
    end

    private

    def call(action, token, **body)
      json(:post, "/cgi-bin/open/#{action}", query: {access_token: token}, body: body)
    end

    def open_appid(data, appid)
      id = data["open_appid"]
      unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,60}\z/) && (!data.key?("appid") || data["appid"] == appid)
        raise HttpConnection::Unavailable, "微信未返回可核实的开放平台绑定关系"
      end
      id
    end

    def confirm(reply, appid, account)
      unless reply["errcode"].to_s == "0" && (!reply.key?("appid") || reply["appid"] == appid) &&
          (!reply.key?("open_appid") || reply["open_appid"] == account)
        raise HttpConnection::Unavailable, "微信未确认目标应用的开放平台操作结果"
      end
    end
  end
end

module Wechat
  class MiniProgramPluginClient < BaseClient
    STATUS_LABELS = { 1 => "申请中", 2 => "申请通过", 3 => "已拒绝", 4 => "已超时" }.freeze
    PLUGIN_APPID = /\A[A-Za-z0-9_]{1,64}\z/

    def list(token)
      response = json(:post, "/wxa/plugin", query: { access_token: token }, body: { action: "list" })
      rows = response.fetch("plugin_list") { [] if response["errcode"].to_s == "0" }
      unless rows.is_a?(Array) && rows.all? { |row| valid_plugin?(row) }
        raise HttpConnection::Unavailable, "微信返回的插件名单不完整，请重新读取"
      end
      rows
    end

    def apply(token, appid) = write(token, action: "apply", plugin_appid: appid)
    def update(token, appid, version) = write(token, action: "update", plugin_appid: appid, user_version: version)
    def unbind(token, appid) = write(token, action: "unbind", plugin_appid: appid)

    private

    def valid_plugin?(row)
      row.is_a?(Hash) && row["appid"].is_a?(String) && PLUGIN_APPID.match?(row["appid"]) &&
        (row["status"].nil? || Integer(row["status"].to_s, exception: false))
    end

    def write(token, **body)
      reply = json(:post, "/wxa/plugin", query: { access_token: token }, body: body)
      raise HttpConnection::Unavailable unless reply["errcode"].to_s == "0"
    rescue HttpConnection::Unavailable
      raise HttpConnection::Unavailable, "微信尚未确认本次插件操作，请先核实当前插件状态"
    end
  end
end

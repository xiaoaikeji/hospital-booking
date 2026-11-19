module Wechat
  class MiniProgramSettingsClient < BaseClient
    def initialize(token, **options)
      super(**options)
      @query = { access_token: token }
    end
    def category_settings
      data = json(:get, "/cgi-bin/wxopen/getcategory", query: @query)
      rows = data["categories"]
      raise HttpConnection::Unavailable, "服务类目响应无效" unless rows.is_a?(Array) && rows.all?(Hash)
      data
    end
    def categories = category_settings.fetch("categories")
    def update_privacy(owner:, settings:)
      result = json(:post, "/cgi-bin/component/setprivacysetting", query: @query, body: { privacy_ver: 2, owner_setting: owner, setting_list: settings })
      raise HttpConnection::Unavailable, "微信未确认隐私指引更新，请重新读取核实" unless result["errcode"] == 0
    end

    def privacy = json(:post, "/cgi-bin/component/getprivacysetting", query: @query, body: { privacy_ver: 2 })
  end
end

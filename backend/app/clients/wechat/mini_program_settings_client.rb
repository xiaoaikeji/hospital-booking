module Wechat
  class MiniProgramSettingsClient < BaseClient
    def initialize(token, **options)
      super(**options)
      @query = { access_token: token }
    end
    def categories
      rows = json(:get, "/cgi-bin/wxopen/getcategory", query: @query)["categories"]
      raise HttpConnection::Unavailable, "服务类目响应无效" unless rows.is_a?(Array) && rows.all?(Hash)
      rows
    end
    def privacy = json(:post, "/cgi-bin/component/getprivacysetting", query: @query, body: { privacy_ver: 2 })
  end
end

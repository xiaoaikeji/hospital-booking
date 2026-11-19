module Wechat
  class MiniProgramCategoryClient < MiniProgramSettingsClient
    def catalog
      rows = json(:get, "/cgi-bin/wxopen/getallcategories", query: @query).dig("categories_list", "categories")
      raise HttpConnection::Unavailable, "微信类目目录响应无效" unless rows.is_a?(Array) && rows.all?(Hash)
      rows
    end

    def add(first, second, certificates, urgent)
      item = { first: first, second: second, certicates: certificates }
      item[:audit_urgent] = 1 if urgent
      confirm_write("/cgi-bin/wxopen/addcategory", categories: [item])
    end

    def remove(first, second)
      confirm_write("/cgi-bin/wxopen/deletecategory", first: first, second: second)
    end

    private

    def confirm_write(path, body)
      result = json(:post, path, query: @query, body: body)
      raise HttpConnection::Unavailable, "微信未确认类目操作结果" unless result.key?("errcode")
    end
  end
end

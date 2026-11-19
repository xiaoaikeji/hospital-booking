module Wechat
  class OfficialAccountLinkClient < BaseClient
    STATUS_LABELS = { 1 => "已关联", 2 => "等待小程序管理员确认", 3 => "小程序管理员已拒绝",
      12 => "等待公众号管理员确认", 13 => "公众号管理员已拒绝" }.freeze

    def initialize(token, **options)
      super(**options)
      @query = { access_token: token }
    end

    def list
      data = json(:post, "/cgi-bin/wxopen/wxamplinkget", query: @query, body: {})
      group = data["wxopens"]
      # 微信的列表可能省略空集合的 items，但不能把残缺/错误响应当成已解除。
      rows = group["items"] if group.is_a?(Hash)
      rows = [] if group.is_a?(Hash) && rows.nil? && group["total_count"].to_s == "0"
      unless rows.is_a?(Array) && rows.all? { |row| valid_row?(row) }
        raise HttpConnection::Unavailable, "微信返回的关联列表不完整"
      end
      raise HttpConnection::Unavailable, "微信返回的关联列表存在重复记录" unless rows.pluck("appid").uniq.size == rows.size
      rows.map { |row| row.slice("appid", "nickname", "status").merge("status" => row["status"].to_i) }
    end

    def link(appid, notify_users:, show_profile:)
      write("/cgi-bin/wxopen/wxamplink", { appid: appid, notify_users: notify_users ? 1 : 0, show_profile: show_profile ? 1 : 0 }, already: 89015)
    end

    def unlink(appid)
      write("/cgi-bin/wxopen/wxampunlink", { appid: appid }, already: 89018)
    end

    private

    def valid_row?(row)
      return false unless row.is_a?(Hash) && row["appid"].is_a?(String)

      row["appid"].match?(/\A[A-Za-z0-9_-]{1,100}\z/) && Integer(row["status"].to_s, exception: false)
    end

    def write(path, body, already:)
      data = json(:post, path, query: @query, body: body)
      raise HttpConnection::Unavailable, "微信尚未确认关联操作" unless data.key?("errcode")
    rescue Rejected => error
      raise unless error.code == already
    end
  end
end

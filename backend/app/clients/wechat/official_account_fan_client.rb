module Wechat
  class OfficialAccountFanClient < BaseClient
    def page(token, cursor)
      data = json(:get, "/cgi-bin/user/get", query: { access_token: token, next_openid: cursor }.compact)
      total, count = data.values_at("total", "count")
      ids = data["data"].is_a?(Hash) ? data["data"]["openid"] : nil
      ids = [] if count == 0 && data["data"].nil?
      unless total.is_a?(Integer) && total >= 0 && count.is_a?(Integer) && ids.is_a?(Array) &&
          ids.size == count && count <= total && ids.all? { |id| valid_id?(id) } &&
          (data["next_openid"].nil? || data["next_openid"].is_a?(String))
        raise HttpConnection::Unavailable, "微信返回的粉丝名单不完整"
      end
      [ids, data["next_openid"].presence, total]
    end

    def profiles(token, ids)
      data = json(:post, "/cgi-bin/user/info/batchget", query: { access_token: token },
        body: { user_list: ids.map { |id| { openid: id, lang: "zh_CN" } } })
      rows = data["user_info_list"]
      unless rows.is_a?(Array) && rows.all? { |row| valid_profile?(row) } && rows.pluck("openid").sort == ids.sort
        raise HttpConnection::Unavailable, "微信返回的粉丝资料不完整"
      end
      rows
    end

    def profile(token, id)
      row = json(:get, "/cgi-bin/user/info", query: { access_token: token, openid: id, lang: "zh_CN" })
      raise HttpConnection::Unavailable, "微信返回的粉丝资料无效" unless valid_profile?(row) && row["openid"] == id
      row
    end

    private

    def valid_id?(id) = id.is_a?(String) && id.length.between?(1, 150)
    def valid_profile?(row)
      row.is_a?(Hash) && valid_id?(row["openid"]) && [0, 1].include?(row["subscribe"]) &&
        (row["unionid"].nil? || valid_id?(row["unionid"]))
    end
  end
end

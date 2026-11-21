module BaiduMap
  class IpLocationClient
    def initialize(connection: HttpConnection.build("https://api.map.baidu.com"))
      @connection = connection
    end

    def locate(address, key)
      response = HttpConnection.request(@connection, :get, "/location/ip", query: { ip: address, ak: key })
      data = HttpConnection.json(response)
      status = Integer(data["status"].to_s, exception: false)
      raise HttpConnection::Unavailable, "百度地图暂时无法查询地区" unless status == 0

      address = data["address"]
      parts = address.is_a?(String) && address.include?("|") ? address.split("|") : []
      content = data["content"]
      details = content["address_detail"] if content.is_a?(Hash)
      details = {} unless details.is_a?(Hash)
      { "country" => text(parts[0]), "province" => text(details["province"]) || text(parts[1]),
        "city" => text(details["city"]) || text(parts[2]) }.compact.presence
    end

    private

    def text(value)
      value = value.strip if value.is_a?(String)
      value if value.is_a?(String) && value.present? && value.length <= 80 &&
        !value.match?(/\A(?:none|null|unknown|0|未知)\z|[[:cntrl:]]/i)
    end
  end
end

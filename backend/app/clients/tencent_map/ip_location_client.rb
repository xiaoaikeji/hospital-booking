module TencentMap
  class IpLocationClient
    def initialize(connection: HttpConnection.build("https://apis.map.qq.com"))
      @connection = connection
    end

    def locate(address, key)
      response = HttpConnection.request(@connection, :get, "/ws/location/v1/ip", query: { ip: address, key: key })
      data = HttpConnection.json(response)
      unless Integer(data["status"].to_s, exception: false) == 0
        raise HttpConnection::Unavailable, "腾讯地图暂时无法查询地区"
      end

      result = data["result"]
      details = result["ad_info"] if result.is_a?(Hash)
      return unless details.is_a?(Hash)
      { "country" => IpLocation.region_name(details["nation"]), "province" => IpLocation.region_name(details["province"]),
        "city" => IpLocation.region_name(details["city"]) }.compact.presence
    end
  end
end

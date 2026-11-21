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
      { "country" => IpLocation.region_name(parts[0]), "province" => IpLocation.region_name(details["province"], parts[1]),
        "city" => IpLocation.region_name(details["city"], parts[2]) }.compact.presence
    end
  end
end

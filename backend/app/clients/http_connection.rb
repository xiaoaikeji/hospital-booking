require "faraday/multipart"

class HttpConnection
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 12

  class Unavailable < StandardError; end

  def self.build(origin, ssl: {})
    Faraday.new(url: origin, request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }, ssl: ssl.merge(verify: true)) do |connection|
      connection.request :multipart
      connection.request :json
      connection.adapter Faraday.default_adapter
    end
  end

  def self.request(connection, method, path, query: {}, body: nil)
    response = connection.public_send(method, path) do |req|
      req.params.update(query)
      req.body = body unless body.nil?
    end
    raise Unavailable, "平台暂不可达或响应无效" unless response.success?
    response
  rescue Faraday::Error
    raise Unavailable, "平台暂不可达，请稍后核实结果", cause: nil
  end

  def self.json(response)
    data = JSON.parse(response.body)
    return data if data.is_a?(Hash)
    raise Unavailable, "平台返回格式无效"
  rescue JSON::ParserError
    raise Unavailable, "平台返回格式无效", cause: nil
  end
end

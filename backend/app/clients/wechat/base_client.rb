module Wechat
  class BaseClient
    class Rejected < StandardError
      attr_reader :code
      def initialize(code)
        @code = code
        super("微信返回错误码 #{code}")
      end
    end

    def initialize(connection: HttpConnection.build("https://api.weixin.qq.com"))
      @connection = connection
    end

    private

    def json(method, path, query: {}, body: nil)
      response = HttpConnection.request(@connection, method, path, query: query, body: body)
      checked(HttpConnection.json(response))
    end

    def checked(data)
      code = Integer(data.fetch("errcode", 0).to_s, exception: false)
      raise HttpConnection::Unavailable, "微信响应无效" unless code
      raise Rejected, code unless code.zero?
      data
    end

    def required(data, key)
      data[key].presence || raise(HttpConnection::Unavailable, "微信响应缺少必要字段")
    end
  end
end

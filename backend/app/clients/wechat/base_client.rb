module Wechat
  class BaseClient
    class Rejected < StandardError
      attr_reader :code
      def invalid_token? = [ 40001, 40014, 42001 ].include?(code)
      def invalid_code? = [ 40029, 40163 ].include?(code)

      def initialize(code)
        @code = code
        hint = { 40001 => "请核对账号凭据", 40013 => "请核对 AppID", 40125 => "请核对 AppSecret",
          40014 => "令牌无效，请重试", 42001 => "令牌已过期，请重试", 48001 => "请核对本账号的接口权限",
          61007 => "该账号缺少接口权限，请在微信公众平台核对" }[code]
        super([ "微信返回错误码 #{code}", hint ].compact.join("，"))
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

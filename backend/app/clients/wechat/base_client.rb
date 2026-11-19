module Wechat
  class BaseClient
    class Rejected < StandardError
      attr_reader :code
      def invalid_token? = [ 40001, 40014, 42001 ].include?(code)

      def initialize(code)
        @code = code
        hint = { 40001 => "请核对凭据并刷新令牌", 40013 => "请核对 AppID", 40125 => "请核对 AppSecret",
          48001 => "请重新授权所需权限", 61007 => "该应用未授权这项接口权限，请更新平台授权",
          85001 => "微信号不存在或无法被搜索", 61023 => "刷新令牌失效，请重新授权", 61039 => "代码检测中，请稍后提交同一体验版" }[code]
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

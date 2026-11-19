module Wechat
  class BaseClient
    class Rejected < StandardError
      attr_reader :code
      def invalid_token? = [ 40001, 40014, 42001 ].include?(code)

      def initialize(code)
        @code = code
        hint = { 40001 => "请核对凭据并刷新令牌", 40013 => "请核对 AppID", 40125 => "请核对 AppSecret",
          48001 => "请重新授权所需权限", 61007 => "该应用未授权这项接口权限，请更新平台授权",
          85001 => "微信号不存在或无法被搜索", 61023 => "刷新令牌失效，请重新授权", 61039 => "代码检测中，请稍后提交同一体验版",
          41033 => "名称检测仅支持通过接口创建的小程序", 53010 => "名称格式不符合微信要求",
          53011 => "检测过于频繁，请稍后再试", 53012 => "微信禁止使用此名称",
          53200 => "本月简介修改次数已用完", 53201 => "简介命中微信限制词，请调整内容",
          53204 => "简介不符合微信要求，请检查长度和中文描述", 53202 => "头像修改次数已用完" }[code]
        hint ||= "名称已被占用" if (53013..53017).cover?(code)
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

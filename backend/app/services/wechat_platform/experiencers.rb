module WechatPlatform
  class Experiencers
    def initialize(app, client: Wechat::MiniProgramTesterClient.new)
      @app, @client = app, client
    end

    def list
      AuthorizerToken.with_token(@app) { |token| @client.list(token) }
    end

    def bind(wechatid)
      raise Error, "请填写有效的体验者微信号" unless wechatid.is_a?(String) && wechatid.strip.length.between?(1, 64)
      AuthorizerToken.with_token(@app) { |token| @client.bind(token, wechatid.strip) }
    end

    def unbind(userstr)
      AuthorizerToken.with_token(@app) do |token|
        raise Error, "该体验者已不在本应用的名单中，请刷新确认" unless @client.list(token).include?(userstr)
        @client.unbind(token, userstr)
      end
    end
  end
end

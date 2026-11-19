module WechatPlatform
  class Experiencers
    def initialize(app, client: Wechat::MiniProgramTesterClient.new)
      @app, @client = app, client
    end

    def list
      with_token { |token| @client.list(token) }
    end

    def bind(wechatid)
      raise Error, "请填写有效的体验者微信号" unless wechatid.is_a?(String) && wechatid.strip.length.between?(1, 64)
      with_token { |token| @client.bind(token, wechatid.strip) }
    end

    def unbind(userstr)
      with_token do |token|
        raise Error, "该体验者已不在本应用的名单中，请刷新确认" unless @client.list(token).include?(userstr)
        @client.unbind(token, userstr)
      end
    end

    private

    def with_token
      token = AuthorizerToken.fetch(@app)
      yield token
    rescue Wechat::BaseClient::Rejected => error
      AuthorizerToken.expire(@app, token) if token && error.invalid_token?
      raise
    end
  end
end

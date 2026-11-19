module WechatPlatform
  class AppPlugins
    def initialize(app, client: Wechat::MiniProgramPluginClient.new)
      @app, @client = app, client
    end

    def list = with_token { |token| @client.list(token) }

    def apply(id)
      change(id) do |token, plugin|
        raise Error, "该插件已申请或已通过，请核对名单" if plugin && [1, 2].include?(plugin["status"].to_i)
        @client.apply(token, id)
      end
    end

    def update(id, version)
      raise Error, "请填写不超过 32 个字符的插件版本号" unless version.present? && version.length <= 32
      change(id) do |token, plugin|
        raise Error, "当前小程序没有此插件，请刷新名单" unless plugin
        raise Error, "该插件已是目标版本" if plugin["version"] == version
        @client.update(token, id, version)
      end
    end

    def unbind(id)
      change(id) do |token, plugin|
        raise Error, "当前小程序没有此插件，请刷新名单" unless plugin
        @client.unbind(token, id)
      end
    end

    private

    def with_token(&block)
      raise Error, "请先完成微信小程序的平台授权" unless @app.code_capable? && @app.platform_authorized?
      AuthorizerToken.with_token(@app, &block)
    end

    def change(id)
      raise Error, "插件 AppID 格式不正确" unless Wechat::MiniProgramPluginClient::PLUGIN_APPID.match?(id)
      App.connection_pool.with_connection do |connection|
        key = connection.quote("booking.wechat.plugin:#{@app.id}:#{id}")
        lock = "hashtextextended(#{key}, 0)"
        raise Error, "此插件正在处理，请稍后重新读取" unless connection.select_value("SELECT pg_try_advisory_lock(#{lock})")
        begin
          with_token do |token|
            plugin = @client.list(token).find { |row| row.fetch("appid") == id }
            yield token, plugin
          end
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{lock})")
        end
      end
    end
  end
end

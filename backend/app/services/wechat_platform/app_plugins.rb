module WechatPlatform
  class AppPlugins
    def initialize(app, client: Wechat::MiniProgramPluginClient.new)
      @app, @client = app, client
    end

    def list
      updates = WechatPluginUpdate.where(app: @app).index_by(&:plugin_appid)
      rows = with_token { |token| @client.list(token) }
      rows.each do |row|
        op = updates[row["appid"]]
        next unless op
        if op.confirmed?
          row["confirmed_version"] = op.version
          row["pending_update"] = op if op.conflicts_with_list?(row["version"])
        elsif row["version"] == op.version
          WechatPluginUpdate.where(id: op.id, confirmed: false).update_all(confirmed: true, updated_at: Time.current)
        else
          row["pending_update"] = op
        end
      end
      rows
    end

    def self.update_allowed?(plugin) = plugin && plugin["status"].to_i == 2 && !plugin["pending_update"]

    def apply(id)
      change(id) do |token, plugin|
        raise Error, "该插件已申请或已通过，请核对名单" if plugin && [1, 2].include?(plugin["status"].to_i)
        @client.apply(token, id)
        WechatPluginUpdate.where(app: @app, plugin_appid: id).delete_all
      end
    end

    def update(id, version)
      raise Error, "请填写不超过 32 个字符的插件版本号" unless version.present? && version.length <= 32
      change(id) do |token, plugin|
        raise Error, "当前小程序没有此插件，请刷新名单" unless plugin
        updates = WechatPluginUpdate.where(app: @app, plugin_appid: id)
        pending = updates.first
        if pending&.conflicts_with_list?(plugin["version"])
          raise Error, "已确认的版本为 #{pending.version}，与微信名单不一致，请先核实"
        end
        if pending && !pending.confirmed?
          raise Error, "上次更新至 #{pending.version} 的结果待核实" unless plugin["version"] == pending.version
          pending.update!(confirmed: true)
        end
        raise Error, "仅申请通过的插件可以更新版本" unless self.class.update_allowed?(plugin)
        actual = plugin["version"].presence || pending&.version
        raise Error, "该插件已是目标版本" if actual == version
        intent = WechatPluginUpdate.transaction do
          pending&.destroy!
          updates.create!(version: version)
        end
        begin
          @client.update(token, id, version)
        rescue Wechat::BaseClient::Rejected => error
          unless error.code == -1
            actual.present? ? intent.update!(confirmed: true, version: actual) : intent.destroy!
          end
          raise
        end
        intent.update!(confirmed: true)
      end
    end

    def verify(id, operation_id, confirmed, actual_version)
      change(id) do |_token, plugin|
        op = WechatPluginUpdate.find_by(app: @app, plugin_appid: id, id: operation_id)
        unless op && confirmed == "1" && (!op.confirmed? || op.conflicts_with_list?(plugin&.dig("version")))
          raise Error, "请刷新并核实本次插件更新"
        end
        unless actual_version.present? && actual_version.length <= 32
          raise Error, "请填写已在微信公众平台核实的实际版本"
        end
        if !plugin || (plugin["version"].present? && actual_version != plugin["version"])
          raise Error, "与微信当前插件名单不符，请刷新"
        end
        op.update!(confirmed: true, version: actual_version)
      end
    end

    def unbind(id)
      change(id) do |token, plugin|
        raise Error, "当前小程序没有此插件，请刷新名单" unless plugin
        @client.unbind(token, id)
        WechatPluginUpdate.where(app: @app, plugin_appid: id).delete_all
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

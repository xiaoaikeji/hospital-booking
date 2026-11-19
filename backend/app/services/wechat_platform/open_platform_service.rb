module WechatPlatform
  class OpenPlatformService
    def initialize(app, actor:, request: nil)
      @app, @actor, @request = app, actor, request
      @client = Wechat::OpenPlatformClient.new
    end

    def create!(name:)
      run("create") do |token|
        raise Error, "账号名称最多 120 个字符" if name.length > 120
        require_unbound!
        remote = @client.bound_appid(@app.appid, token)
        unless remote
          reserve!("create", name: name)
          remote = dispatch(token) { @client.create(@app.appid, token) }
        end
        save_binding!("create", remote, name: name)
      end
    end

    def bind!(account)
      run("bind") do |token|
        require_unbound!
        remote = @client.bound_appid(@app.appid, token)
        if remote && remote != account.open_appid
          raise Error, "该应用在微信已绑定其他账号，请先同步绑定状态"
        end
        unless remote
          reserve!("bind", account: account)
          remote = dispatch(token) do
            @client.bind(@app.appid, account.open_appid, token)
            account.open_appid
          end
          raise Error, "微信当前绑定与目标账号不一致，请同步绑定状态" unless remote == account.open_appid
        end
        save_binding!("bind", account.open_appid)
      end
    end

    def unbind!(account)
      run("unbind") do |token|
        raise Error, "该应用当前未绑定此账号，请刷新" unless @app.open_platform_account_id == account.id
        remote = @client.bound_appid(@app.appid, token)
        if remote && remote != account.open_appid
          raise Error, "微信当前绑定与本地不同，请先同步绑定状态"
        end
        if remote
          reserve!("unbind", account: account)
          dispatch(token) { @client.unbind(@app.appid, account.open_appid, token) }
        end
        save_binding!("unbind", nil)
      end
    end

    def sync!
      run("sync") do |token|
        remote = @client.bound_appid(@app.appid, token)
        save_binding!("sync", remote, name: @operation&.name)
      end
    end

    private

    # 会话锁不依赖外层事务；发请求前已提交的意图在进程退出或本地回写失败后仍可核实。
    def run(action)
      raise Error, "需要超级管理员权限" unless @actor&.super_admin?
      App.connection_pool.with_connection do |connection|
        key = "hashtextextended('booking.wechat.open_platform:#{Integer(@app.id)}', 0)"
        raise Error, "该应用正在处理开放平台操作，请稍后刷新" unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        begin
          @app.reload
          @operation = OpenPlatformOperation.find_by(app_id: @app.id)
          raise Error, "请先核实上次操作，使用「同步绑定状态」读取微信结果" if @operation && action != "sync"
          raise Error, "请先完成该微信应用的平台授权" unless @app.platform_authorized?
          AuthorizerToken.with_token(@app) { |token| yield token }
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      audit(action, "failed", reason: error.message, operation_id: @operation&.id) if @actor&.super_admin?
      raise
    rescue ActiveRecord::ActiveRecordError
      message = "开放平台结果未能登记，请同步绑定状态核实后再操作"
      audit(action, "failed", reason: message, operation_id: @operation&.id)
      raise Error, message
    end

    def require_unbound!
      raise Error, "该应用已有绑定账号，请刷新页面" if @app.open_platform_account_id
    end

    def reserve!(action, account: nil, name: nil)
      OpenPlatformOperation.transaction do
        @operation = OpenPlatformOperation.create!(app: @app, action: action, open_platform_account: account, name: name)
        audit(action, "started", operation_id: @operation.id, open_appid: account&.open_appid)
      end
    end

    def dispatch(token)
      yield
    rescue Wechat::BaseClient::Rejected => error
      if error.code == 89000 && @operation.action.in?(%w[bind create])
        # 微信称已绑定时要用目标应用的令牌读回实际账号。读回失败仍保留意图。
        return @client.bound_appid(@app.appid, token) || raise(Error, "微信报告已绑定但未返回账号，请同步绑定状态")
      end
      raise Error, "微信服务繁忙，操作结果待核实，请同步绑定状态" if error.code == -1
      @operation.destroy!
      raise
    rescue HttpConnection::Unavailable
      raise Error, "微信暂未确认结果，请先同步绑定状态"
    end

    def save_binding!(action, open_appid, name: nil)
      OpenPlatformAccount.transaction do
        previous = @app.open_platform_account
        account = if open_appid
          OpenPlatformAccount.find_or_create_by!(open_appid: open_appid) do |row|
            row.assign_attributes(name: name.presence || "开放平台账号 #{open_appid}", created_via_app: @app, operator: @actor)
          end
        end
        @app.update!(open_platform_account: account)
        account&.update!(operator: @actor)
        previous&.update!(operator: @actor) if previous && previous != account
        details = {open_appid: open_appid, previous_open_appid: previous&.open_appid, operation_id: @operation&.id}
        if action == "sync" && @operation
          details[:verified_action] = @operation.action
          details[:expected_open_appid] = @operation.open_platform_account&.open_appid
        end
        audit(action, "success", **details)
        @operation&.destroy!
        account
      end
    end

    def audit(action, status, **details)
      WechatPlatform.log!(@app, "open_platform_#{action}", actor: @actor, request: @request, status: status, details: details.compact)
    end
  end
end

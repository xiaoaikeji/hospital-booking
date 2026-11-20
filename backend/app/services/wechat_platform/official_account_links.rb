module WechatPlatform
  class OfficialAccountLinks
    REJECTED = [3, 13].freeze
    EVENTS = %w[wechat.link_create wechat.link_delete wechat.link_verify].freeze

    def initialize(app, actor: nil, request: nil)
      @app, @actor, @request = app, actor, request
      raise Error, "请选择微信公众号" unless app.provider == "wechat" && app.app_type == "official_account"
    end

    def page
      snapshot = Rails.cache.read(cache_key)
      live = false
      if @app.platform_authorized?
        begin
          snapshot = with_client { |client| read(client) }
          live = true
        rescue HttpConnection::Unavailable, Wechat::BaseClient::Rejected, Error => error
          problem = error.message
        end
      end
      rows = snapshot&.fetch(:rows) || []
      operations = WechatLinkOperation.where(app: @app).order(id: :desc).to_a
      statuses = rows.to_h { |r| [r["appid"], r["status"]] }
      pending = operations.select { |op| op.awaiting_verification?(statuses[op.mini_appid]) }
      apps = App.wechat_mini_programs.order(:nickname, :appid).index_by(&:appid)
      unavailable = statuses.filter_map { |id, status| id unless REJECTED.include?(status) } + pending.map(&:mini_appid)
      { rows: rows, apps: apps, candidates: apps.except(*unavailable).values, pending: pending,
        live: live, error: problem, fetched_at: snapshot&.fetch(:at), revision: revision(rows),
        history: Log.where(target_type: "App", target_id: @app.id, category: "wechat", action: EVENTS).where.not(status: "started").order(id: :desc).limit(10) }
    end

    def change!(action, input)
      require_admin!
      raise Error, "不支持此关联操作" unless %w[create delete].include?(action)
      mini = App.wechat_mini_programs.find_by(id: input[:mini_program_id]) if action == "create"
      target = action == "create" ? mini&.appid : input[:id].to_s
      raise Error, "请选择本院已登记的微信小程序" unless target&.match?(/\A[A-Za-z0-9_-]{1,100}\z/)
      notify, profile = input.values_at(:notify_users, :show_profile).map { |value| value == "1" }
      locked(target) do
        with_client do |client|
          rows = read(client).fetch(:rows)
          raise Error, "关联状态已变化，请刷新后再操作" unless input[:revision] == revision(rows)
          remote = status(rows, target)
          op = WechatLinkOperation.find_or_initialize_by(app: @app, mini_appid: target)
          raise Error, "请先核实上次关联操作" if op.awaiting_verification?(remote)
          if action == "create"
            raise Error, "该小程序已关联或正在等待管理员确认" if remote && !REJECTED.include?(remote)
          elsif !remote
            raise Error, "微信当前列表中没有这条关联"
          end
          WechatLinkOperation.transaction do
            mini ||= App.wechat_mini_programs.find_by(appid: target)
            op.update!(action: action, previous_status: remote, state: "started", mini_program_id: mini&.id)
            log(action, target, "started")
          end
          begin
            action == "create" ? client.link(target, notify_users: notify, show_profile: profile) : client.unlink(target)
          rescue HttpConnection::Unavailable
            raise Error, "微信尚未确认本次操作，请在下方核实微信记录后再继续"
          rescue Wechat::BaseClient::Rejected => error
            raise Error, "微信系统繁忙，请先核实本次操作" if error.code == -1
            op.update!(state: "failed")
            raise
          end
          WechatLinkOperation.transaction do
            op.update!(state: "accepted")
            details = action == "create" ? { notify_users: notify, show_profile: profile } : {}
            log(action, target, "success", **details)
          end
        end
      end
    rescue Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected, ActiveRecord::ActiveRecordError => error
      fail_action!(action, target, error)
    end

    def verify!(input)
      require_admin!
      op = WechatLinkOperation.where(app: @app).find_by(id: input[:operation_id]) || raise(Error, "未找到本公众号的待核实操作")
      locked(op.mini_appid) do
        op.reload
        rows = with_client { |client| read(client, observe: false).fetch(:rows) }
        remote = status(rows, op.mini_appid)
        unless %w[started accepted].include?(op.state) && op.lock_version.to_s == input[:version] && input[:confirmed] == "1"
          raise Error, "请刷新后核实当前操作"
        end
        applied = op.observed?(remote)
        if !applied && remote != op.previous_status
          raise Error, "微信关联状态存在变更，请先核实本次操作"
        end
        expected = applied ? "applied" : "not_applied"
        raise Error, "核实结果与微信当前关联状态不一致" unless input[:outcome] == expected
        WechatLinkOperation.transaction do
          op.update!(state: expected)
          log("verify", op.mini_appid, "success", outcome: expected)
        end
      end
    rescue Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected, ActiveRecord::ActiveRecordError => error
      fail_action!("verify", op&.mini_appid, error)
    end

    private

    def require_admin!
      raise Error, "需要超级管理员权限" unless @actor&.super_admin?
    end

    def read(client, observe: true)
      # Record only transitions returned after the operation was accepted.
      # Compare the version so a late response cannot settle a newer attempt.
      accepted = observe ? WechatLinkOperation.where(app: @app, state: "accepted").to_a : []
      snapshot = { rows: client.list, at: Time.current }
      statuses = snapshot[:rows].to_h { |row| row.values_at("appid", "status") }
      accepted.each do |op|
        next unless op.observed?(statuses[op.mini_appid])
        WechatLinkOperation.where(id: op.id, lock_version: op.lock_version, state: "accepted").update_all(state: "applied", updated_at: Time.current)
      end
      Rails.cache.write(cache_key, snapshot, expires_in: 7.days)
      snapshot
    end

    def with_client(&block)
      AuthorizerToken.with_token(@app) { |token| block.call(Wechat::OfficialAccountLinkClient.new(token)) }
    end

    def revision(rows)
      states = WechatLinkOperation.where(app: @app).order(:id).pluck(:id, :lock_version)
      Digest::SHA256.hexdigest([@app.id, rows.map { |row| row.values_at("appid", "status") }.sort, states].to_json)
    end

    def status(rows, target) = rows.find { |row| row["appid"] == target }&.fetch("status")
    def cache_key = "wechat/apps/#{@app.id}/official_account_links"

    def locked(target)
      App.connection_pool.with_connection do |connection|
        key = connection.quote("booking.wechat.links:#{@app.id}:#{target}")
        raise Error, "该关联正在处理，请稍后刷新" unless connection.select_value("SELECT pg_try_advisory_lock(hashtextextended(#{key}, 0))")
        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))")
        end
      end
    end

    def log(action, target, state, **details)
      WechatPlatform.log!(@app, "link_#{action}", actor: @actor, request: @request, status: state,
        details: details.merge(mini_appid: target))
    end

    def fail_action!(action, target, error)
      message = error.is_a?(ActiveRecord::ActiveRecordError) ? "本地记录未完整保存，请先核实微信结果" : error.message
      log(action, target, "failed", reason: message) if @actor&.super_admin?
      raise Error, message
    end
  end
end

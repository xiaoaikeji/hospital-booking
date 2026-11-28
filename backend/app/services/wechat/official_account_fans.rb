module Wechat
  class OfficialAccountFans
    def initialize(app)
      @app = app
      @client = Wechat::OfficialAccountFanClient.new
    end

    def request_sync!(actor, request: nil)
      raise Error, "需要超级管理员权限" unless actor.super_admin?
      run = @app.with_lock do
        require_direct_access!
        previous = OfficialAccountFanSync.active.find_by(app: @app)
        return false if previous&.busy?
        finish!(previous, "failed", error: "任务已中断") if previous
        row = OfficialAccountFanSync.create!(app: @app, operator: actor)
        Wechat.log!(@app, "fan_sync", actor: actor, request: request, status: "started", details: { sync_id: row.id })
        row
      end
      begin
        raise Error, "同步任务未能排队，请重试" unless WechatPlatform::FanSyncWorker.perform_async(run.id)
      rescue StandardError
        finish!(run, "failed", error: "同步任务未能排队，请重试")
        raise Error, "同步任务未能排队，请重试"
      end
      true
    end

    def sync!(run)
      # PostgreSQL 会话锁随进程退出释放。同一任务重投可从头读取，已完成或被新任务替代的轮次直接返回。
      OfficialAccountFanSync.connection_pool.with_connection do |connection|
        key = "hashtextextended('booking.fan_sync:#{Integer(run.id)}', 0)"
        return unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        begin
          @app.with_lock do
            return if run.reload.state == "success" || OfficialAccountFanSync.where(app: @app).where("id > ?", run.id).exists?
            require_direct_access!
            run.update!(state: "running", error: nil)
          end
          pull!(run)
        rescue Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
          finish!(run, "failed", error: error.message)
          raise if error.is_a?(HttpConnection::Unavailable) || (error.is_a?(Wechat::BaseClient::Rejected) && (error.invalid_token? || error.code == -1))
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end

    def event!(openid, event, seconds, qr_scene)
      require_direct_access!
      at = Time.zone.at(seconds)
      existing = UserApp.for_app(@app).find_by(openid: openid)&.official_account_fan
      return if existing&.supersedes?(at, event: event, subscribed: event == "subscribe")
      info = { "openid" => openid, "subscribe" => 0 }
      if event == "subscribe"
        begin
          info = AccessToken.with_token(@app) { |token| @client.profile(token, openid) }
        rescue Wechat::BaseClient::Rejected, HttpConnection::Unavailable
          # 已验签的再次关注仍然生效。新身份需要先取到资料，交给任务重试。
          raise unless existing
          info = { "openid" => openid, "subscribe" => 1 }
        end
      end
      @app.with_lock do
        require_direct_access!
        save_profile!(info, at, event: event, qr_scene: qr_scene)
      end
    end

    private

    def require_direct_access!
      raise Error, "请选择微信公众号" unless @app.wechat_official_account?
      AccessToken.credential!(@app)
    end

    def pull!(run)
      started = Time.current
      seen = Set.new
      cursors = Set.new
      cursor = nil
      loop do
        ids, following, total = AccessToken.with_token(@app) { |token| @client.page(token, cursor) }
        raise Error, "微信名单出现重复记录，请重新同步" unless ids.all? { |id| seen.add?(id) }
        ids.each_slice(100) do |batch|
          profiles = AccessToken.with_token(@app) { |token| @client.profiles(token, batch) }
          @app.with_lock do
            return unless run.reload.state == "running"
            require_direct_access!
            profiles.each { |row| save_profile!(row, started) }
            run.touch
          end
        end
        if following.nil?
          raise Error, "微信名单数量未核对通过，请重新同步" unless seen.size == total
          break
        end
        raise Error, "微信分页游标异常，请重新同步" if ids.empty? || !cursors.add?(following)
        cursor = following
      end
      @app.with_lock do
        return unless run.reload.state == "running"
        require_direct_access!
        OfficialAccountFan.for_app(@app).where(subscribed: true, observed_at: ...started, updated_at: ...started)
          .update_all(subscribed: false, observed_at: started, updated_at: Time.current)
        finish!(run, "success", fan_count: OfficialAccountFan.for_app(@app).where(subscribed: true).count)
      end
    end

    def finish!(run, state, **attributes)
      run.with_lock do
        return unless run.state.in?(%w[queued running])
        run.update!(state: state, **attributes)
        Log.record!(category: "wechat", source: "job", action: "wechat.fan_sync", actor: run.operator,
          target: @app, status: state, details: { sync_id: run.id, **attributes })
      end
    end

    def save_profile!(info, at, event: nil, qr_scene: nil)
      subscribed = info["subscribe"] == 1
      identity = UserApp.for_app(@app).find_by(openid: info["openid"])
      return if !identity && !subscribed && !event
      fan = identity&.official_account_fan
      return if fan&.supersedes?(at, event: event, subscribed: subscribed)

      # Existing identities keep their user; new followers belong to this official account.
      identity ||= UserApp.create!(app: @app, user: User.create!(platform: "wechat"), openid: info.fetch("openid"))
      fan ||= identity.build_official_account_fan
      fan.assign_attributes(observed_at: at, subscribed: subscribed)
      fan.event_at = at if event
      if subscribed
        followed = info["subscribe_time"].to_i
        fan.subscribed_at = event ? at : Time.zone.at(followed) if event || followed.positive?
        fan.unsubscribed_at = nil
        scene = info["subscribe_scene"].presence
        scene_key = qr_scene.presence || info["qr_scene_str"].presence
        fan.scene = scene if event || scene
        # 微信没有返回新的扫码渠道时保留最近一次扫码关注来源，供渠道人数统计。
        fan.qr_scene = scene_key if scene_key
      elsif event == "unsubscribe"
        fan.unsubscribed_at = at
      end
      fan.save!
    end
  end
end

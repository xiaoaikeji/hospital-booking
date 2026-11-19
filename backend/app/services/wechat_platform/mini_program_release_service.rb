module WechatPlatform
  class MiniProgramReleaseService
    RESULTS = { "0" => "passed", "1" => "rejected", "2" => "pending", "3" => "withdrawn", "4" => "delayed" }.freeze

    def initialize(app, actor: nil, request: nil)
      @app, @actor, @request = app, actor, request
    end

    def upload!(attributes)
      operation("upload") do
        api = client
        previous = @app.mini_program_releases.find_by(current_build: true)
        release = App.transaction do
          previous&.update!(current_build: false)
          @app.mini_program_releases.create!(attributes.merge(operator: @actor))
        end
        begin
          api.upload(release)
        rescue Wechat::BaseClient::Rejected => error
          unless error.code == -1
            App.transaction do
              release.update!(status: "upload_failed", error_code: error.code)
              previous&.update!(current_build: true)
            end
          end
          raise
        end
        @remote = "已上传"
        App.transaction do
          release.update!(status: "uploaded", current_build: true)
          log!(release_id: release.id)
        end
        release
      end
    end

    def verify_upload!(release)
      operation("resolve", release) do
        unless release.reload.status == "upload_unknown" && @app.mini_program_releases.maximum(:id) == release.id
          raise Error, "只能核实最近一次结果待定的上传"
        end
        experience = client.version_info["exp_info"]
        unless experience && experience["exp_version"] == release.version && experience["exp_desc"] == release.description
          raise Error, "微信体验版与本记录不一致，请继续核实"
        end
        App.transaction do
          release.update!(status: "uploaded", current_build: true)
          log!(release_id: release.id, result: "已人工核实微信体验版模板与版本")
        end
      end
    end

    def trial(release)
      raise Error, "请选择当前体验版" unless release.app_id == @app.id && release.current_build? && release.status == "uploaded"
      client.trial_qrcode
    end

    def submit!(release, description:, auto_publish:, expected_round:)
      operation("submit", release) do
        release.reload
        raise Error, "请选择当前体验版" unless release.current_build? && release.status == "uploaded"
        guard_unresolved!
        if @app.mini_program_audits.maximum(:id).to_i != expected_round.to_i
          raise Error, "已有更新轮次，请刷新页面"
        end
        api = client
        experience = api.version_info["exp_info"]
        if experience.present? && (experience["exp_version"] != release.version || experience["exp_desc"].to_s != release.description)
          raise Error, "微信体验版与本记录不符，请核实当前上传版本"
        end
        previous_id = api.latest_id
        audit = @app.with_lock do
          config = AppConfiguration.new(@app)
          config.verify! if @app.accessible? && (@app.status == "active" || config.credential_status != "已验证")
          row = @app.mini_program_audits.create!(mini_program_release: release, previous_audit_id: previous_id,
            version: release.version, description: description.presence || release.description,
            auto_publish: auto_publish, operator: @actor, previous_status: @app.status)
          @app.update!(status: "auditing") if @app.status == "active"
          row
        end
        begin
          id = api.submit(audit.description)
        rescue Wechat::BaseClient::Rejected => error
          raise if error.code == -1
          @app.with_lock do
            audit.update!(status: "not_accepted", error_code: error.code)
            @app.update!(status: audit.previous_status) if @app.status == "auditing"
          end
          raise
        end
        @remote = "微信已受理，审核单号 #{id}"
        App.transaction do
          audit.update!(audit_id: id, status: "pending")
          log!(round_id: audit.id, audit_id: id)
        end
        audit
      end
    end

    def sync!(audit)
      operation("sync", audit) do
        audit.reload
        api = client
        if audit.status == "submit_unknown"
          candidate = api.latest_id
          raise Error, "微信最新单号与提交前相同，受理结果仍待核实" if candidate == audit.previous_audit_id
          raise Error, "请在微信核实本轮版本与审核单号 #{candidate} 后登记" if candidate
          raise Error, "尚未查到本轮单号，请在微信核实后处理"
        end
        if audit.publication == "publish_unknown"
          reconcile_publication!(api, audit)
        elsif MiniProgramAudit::PENDING.include?(audit.status)
          apply_result!(audit, remote_status(api, audit.audit_id))
        elsif audit.audit_id
          result = remote_status(api, audit.audit_id)
          raise Error, "微信结果与已归档轮次不符，请核实" unless result == audit.status
          log!(round_id: audit.id, result: result)
        else
          raise Error, "本轮未受理，没有可查询的微信审核单"
        end
      end
    end

    # 最新单号本身不能证明版本归属。管理员在微信后台核实版本后，再以本应用的令牌逐单复查。
    def resolve!(audit, outcome:, confirmed_id:)
      operation("resolve", audit) do
        audit.reload
        api = client
        if audit.publication == "publish_unknown" && outcome == "published"
          reconcile_publication!(api, audit, confirmed: true)
        elsif audit.publication == "publish_unknown" && outcome == "not_published"
          raise Error, "线上版本已变更，请先同步发布结果" unless online_marker(api.version_info) == audit.prior_online_marker
          App.transaction do
            audit.update!(publication: "failed")
            log!(round_id: audit.id, result: "人工核实未发布")
          end
        elsif audit.status == "withdraw_unknown" && outcome == "not_withdrawn"
          state = remote_status(api, audit.audit_id)
          raise Error, "审核状态已改变，请同步结果" unless %w[pending delayed].include?(state)
          apply_result!(audit, state, confirmed: true)
        else
          raise Error, "该轮提审已核实" unless audit.status == "submit_unknown"
          candidate = api.latest_id
          if outcome == "accepted"
            id = confirmed_id.to_s.strip
            raise Error, "单号不匹配，请在微信核实本轮版本" unless id.present? && id == candidate && id != audit.previous_audit_id
            result = remote_status(api, id)
            audit.audit_id = id
            apply_result!(audit, result)
          elsif outcome == "not_accepted" && candidate == audit.previous_audit_id
            @app.with_lock do
              audit.update!(status: "not_accepted")
              @app.update!(status: audit.previous_status) if @app.status == "auditing"
              log!(round_id: audit.id, result: "人工核实未受理")
            end
          else
            raise Error, "核实结果与微信最新单号不符"
          end
        end
      end
    end

    def withdraw!(audit)
      operation("withdraw", audit) do
        audit.reload
        raise Error, "只能撤回当前在审轮次" unless latest_round?(audit) && %w[pending delayed].include?(audit.status)
        api = client
        raise Error, "微信最新单号已变化，请先核实" unless api.latest_id == audit.audit_id
        before = remote_status(api, audit.audit_id)
        raise Error, "微信审核已结束，请先同步" unless %w[pending delayed].include?(before)
        audit.update!(status: "withdraw_unknown")
        begin
          api.withdraw
        rescue Wechat::BaseClient::Rejected => error
          audit.update!(status: before, error_code: error.code) unless error.code == -1
          raise
        end
        @remote = "微信已确认撤回"
        apply_result!(audit, "withdrawn")
      end
    end

    def publish!(audit, automatic: false)
      operation("publish", audit) do
        audit.reload
        next if audit.publication == "published"
        if audit.publication == "publish_unknown"
          next reconcile_publication!(client, audit)
        end
        eligible = audit.status == "passed" && latest_round?(audit) && audit.mini_program_release &&
          audit.mini_program_release.status != "closed"
        next if automatic && !(eligible && audit.auto_publish? && audit.publication == "unpublished")
        raise Error, "只能发布最新通过的有效轮次" unless eligible
        api = client
        unless api.latest_id == audit.audit_id && remote_status(api, audit.audit_id) == "passed"
          raise Error, "微信最新通过单与本轮不符，请核实"
        end
        audit.update!(publication: "publish_unknown", prior_online_marker: online_marker(api.version_info))
        begin
          api.publish
        rescue Wechat::BaseClient::Rejected => error
          next reconcile_publication!(api, audit) if error.code == 85052
          audit.update!(publication: "failed", error_code: error.code) unless error.code == -1
          raise
        end
        @remote = "微信已确认发布"
        mark_published!(audit)
      end
    end

    def retire!(release, delete:)
      operation(delete ? "delete" : "close", release) do
        App.transaction do
          delete ? release.destroy! : release.update!(status: "closed", current_build: false)
          log!(release_id: release.id)
        end
      end
    end

    private

    def online_marker(info)
      online = info["release_info"] || {}
      Digest::SHA256.hexdigest(online.values_at("release_version", "release_desc", "release_time").to_json)
    end

    def reconcile_publication!(api, audit, confirmed: false)
      info = api.version_info
      same_version = info.dig("release_info", "release_version") == audit.version
      if same_version && (confirmed || online_marker(info) != audit.prior_online_marker) && api.latest_id == audit.audit_id
        mark_published!(audit)
      else
        raise Error, "线上版本尚不能确认本轮发布结果，请核实后再操作"
      end
    end

    def mark_published!(audit)
      App.transaction do
        audit.update!(publication: "published")
        log!(round_id: audit.id, audit_id: audit.audit_id, result: "已发布")
      end
    end

    def remote_status(api, id)
      data = api.status(id)
      if data["auditid"].present? && data["auditid"].to_s != id
        raise Error, "微信返回的审核单号不符"
      end
      RESULTS.fetch(data["status"].to_s) { raise Error, "未知微信审核状态，请稍后核实" }
    end

    def latest_round?(audit)
      @app.mini_program_audits.accepted_or_uncertain.maximum(:id) == audit.id
    end

    def apply_result!(audit, result, confirmed: false)
      @app.with_lock do
        # 未明确撤回失败前，查询仍在审不代表可以再次扣减撤回配额。
        unless audit.status == "withdraw_unknown" && %w[pending delayed].include?(result) && !confirmed
          audit.update!(status: result)
        end
        latest = latest_round?(audit)
        if latest && @app.status == "auditing" && !MiniProgramAudit::PENDING.include?(result)
          @app.update!(status: "active")
        end
        log!(round_id: audit.id, audit_id: audit.audit_id, result: audit.status)
        if latest && result == "passed" && audit.auto_publish? && audit.publication == "unpublished" &&
            audit.mini_program_release && audit.mini_program_release.status != "closed"
          ActiveRecord.after_all_transactions_commit do
            AutoPublishWorker.perform_async(audit.id)
          rescue RedisClient::Error
            Rails.logger.warn("微信自动发布入队失败，等待定时补查 round=#{audit.id}")
          end
        end
      end
    end

    def guard_unresolved!
      audits = @app.mini_program_audits
      if audits.where(status: %w[submit_unknown withdraw_unknown]).exists? || audits.exists?(publication: "publish_unknown")
        raise Error, "该应用有待核实结果，请先查询微信记录"
      end
    end

    def client
      @api_token = AuthorizerToken.fetch(@app)
      Wechat::MiniProgramCodeClient.new(@api_token)
    end

    def log!(**details)
      WechatPlatform.log!(@app, @action, actor: @actor, request: @request, details: details)
    end

    # 应用锁跨越意图提交、微信请求、结果落库三个阶段。网络调用期间终端仍可读到已提交的状态。
    def operation(action, record = nil)
      @action, @remote, @api_token = action, nil, nil
      raise Error, "记录不属于当前应用" if record && record.app_id != @app.id
      raise Error, "请选择微信应用" unless @app.provider == "wechat"
      App.connection_pool.with_connection do |connection|
        key = "hashtextextended('booking.wechat.release:#{Integer(@app.id)}', 0)"
        connection.execute("SELECT pg_advisory_lock(#{key})")
        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    rescue Error, AppConfiguration::Invalid, HttpConnection::Unavailable, Wechat::BaseClient::Rejected, ActiveRecord::ActiveRecordError => error
      if @api_token && error.is_a?(Wechat::BaseClient::Rejected) && error.invalid_token?
        AuthorizerToken.expire(@app, @api_token)
      end
      reason = case error
      when ActiveRecord::RecordInvalid then "记录校验失败，请核对填写内容"
      when ActiveRecord::ActiveRecordError then "本地写入失败，请先核实微信结果"
      else error.message
      end
      WechatPlatform.log!(@app, action, actor: @actor, request: @request, status: "failed",
        details: { reason: reason, remote_result: @remote }.compact)
      raise Error, [ @remote, reason ].compact.join("；"), cause: nil
    end
  end
end

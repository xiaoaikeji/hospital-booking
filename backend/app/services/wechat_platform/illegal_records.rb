module WechatPlatform
  class IllegalRecords
    def self.enabled? = Setting.where(key: "wechat_notifications").pick(:settings)&.fetch("pull_violations", false) == true

    def self.sync(app, appeals_only: false, now: Time.current)
      return unless enabled? && app.code_capable? && app.platform_authorized? && ComponentToken.new.missing.empty?
      # Serialize remote snapshots for this app without holding an application row lock during network I/O.
      App.connection_pool.with_connection do |connection|
        key = connection.quote("booking.wechat.violations:#{app.id}")
        lock = "hashtextextended(#{key}, 0)"
        return unless connection.select_value("SELECT pg_try_advisory_lock(#{lock})")
        begin
          new(app, now).sync(appeals_only)
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{lock})")
        end
      end
    rescue Wechat::BaseClient::Rejected, HttpConnection::Unavailable, Error => error
      log_failure(app, error)
    end

    def self.log_failure(app, error)
      Log.record!(source: "system", category: "wechat", action: "wechat.violation_sync", status: "failed", target: app,
        details: { error: error.class.name, code: (error.code if error.respond_to?(:code)) }.compact)
    end

    def initialize(app, now)
      @app, @now = app, now
    end

    def sync(appeals_only)
      baseline = @app.reload.violations_synced_at.nil?
      unless appeals_only
        rows = with_client { |api| api.violations(@now) }
        @app.with_lock do
          return unless @app.platform_authorized?
          rows.each { |row| record_violation(row, baseline) }
          @app.update_column(:violations_synced_at, @now)
        end
      end
      scope = @app.wechat_violations
      pending = WechatAppeal.where(status: 1).select(:wechat_violation_id)
      scope.where(occurred_at: (@now - 30.days)..).or(scope.where(id: pending)).find_each do |record|
        rows = with_client { |api| api.appeals(record.record_number) }
        record.transaction { rows.each { |row| record_appeal(record, row, baseline) } }
      rescue Wechat::BaseClient::Rejected, HttpConnection::Unavailable, Error => error
        self.class.log_failure(@app, error)
      end
    end

    private

    def with_client
      AuthorizerToken.with_token(@app) { |token| yield Wechat::MiniProgramIllegalRecordClient.new(token) }
    end

    def timestamp(value)
      seconds = Integer(value.to_s, 10, exception: false)
      Time.zone.at(seconds) if seconds&.positive? && seconds <= 253402300799
    end

    def record_violation(row, baseline)
      number, at = row["illegal_record_id"].to_s, timestamp(row["create_time"])
      raise HttpConnection::Unavailable, "微信违规记录缺少编号或时间" unless number.present? && number.length <= 128 && at
      record = @app.wechat_violations.find_or_initialize_by(record_number: number)
      return if record.persisted?
      record.update!(occurred_at: at, reason: row["illegal_reason"], content: row["illegal_content"],
        rule_name: row["rule_name"], rule_url: row["rule_url"])
      WechatPlatform::ResultNotifications.violation(record) unless baseline
    end

    def record_appeal(record, row, baseline)
      number = row["appeal_record_id"].to_s
      status = Integer(row["appeal_status"].to_s, 10, exception: false)
      return unless number.match?(/\A\d{1,64}\z/) && WechatAppeal::STATUSES.key?(status)
      appeal = record.appeals.find_or_initialize_by(number: number)
      previous = appeal.status
      appeal.update!(status: status, appealed_at: timestamp(row["appeal_time"]), audited_at: timestamp(row["audit_time"]),
        reason: row["audit_reason"], punishment: row["punish_description"])
      return if baseline || previous == status || status == 4
      return if previous.nil? && !(status == 1 && appeal.appealed_at && appeal.appealed_at >= @now - 30.days)
      WechatPlatform::ResultNotifications.appeal(appeal)
    end
  end
end

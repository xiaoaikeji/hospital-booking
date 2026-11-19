module WechatPlatform
  class CategoryAuditEventWorker
    include Sidekiq::Job

    def perform(app_id, first, second, result, occurred_at)
      app = App.wechat_mini_programs.find_by(id: app_id)
      return unless app
      app.with_lock do
        return unless app.platform_authorized?
        event_digest = Digest::SHA256.hexdigest([first, second, result, occurred_at].to_json)
        events = Log.where(target_type: "App", target_id: app.id, source: "system", action: "wechat.category_audit")
        return if events.where("details ->> 'event_digest' = ?", event_digest).exists?
        Log.record!(category: "wechat", action: "wechat.category_audit", source: "system", target: app,
          details: { first: first, second: second, result: result, occurred_at: occurred_at, event_digest: event_digest })
        ResultNotifications.category(app, first, second, result, occurred_at)
      end
    end
  end
end

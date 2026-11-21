module WechatPlatform
  class CategoryAuditEventWorker
    include Sidekiq::Job

    def perform(app_id, first, second, result, occurred_at, reason = nil)
      app = App.wechat_mini_programs.find_by(id: app_id)
      return unless app&.platform_authorized?

      event_digest = Digest::SHA256.hexdigest([first, second, result, occurred_at].to_json)
      events = Log.where(target_type: "App", target_id: app.id, source: "system", action: "wechat.category_audit")
        .where("details ->> 'event_digest' = ?", event_digest)
      return if events.exists?

      name = AppCategories.new(app).category_name(first, second)
      app.with_lock do
        return unless app.platform_authorized? && !events.exists?
        Log.record!(category: "wechat", action: "wechat.category_audit", source: "system", target: app,
          details: { first: first, second: second, result: result, occurred_at: occurred_at, event_digest: event_digest })
        ResultNotifications.category(app, first, second, result, occurred_at, name: name, reason: reason)
      end
    end
  end
end

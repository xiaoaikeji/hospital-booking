module WechatPlatform
  class NotificationWorker
    include Sidekiq::Job
    sidekiq_options retry: false

    def perform(event_id = nil)
      return ResultNotifications.deliver(event_id) if event_id
      WechatNotificationEvent.where(status: "sending", updated_at: ..10.minutes.ago).update_all(status: "unknown", updated_at: Time.current)
      WechatNotificationEvent.where(status: "pending").in_batches(of: 100) do |batch|
        batch.pluck(:id).each { |id| self.class.perform_async(id) }
      end
    end
  end
end

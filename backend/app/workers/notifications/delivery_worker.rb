module Notifications
  class DeliveryWorker
    include Sidekiq::Job
    sidekiq_options retry: false

    def perform(id = nil)
      return Delivery.run(id, job_id: jid) if id
      Notification.where(status: "pending").where("scheduled_at IS NULL OR scheduled_at <= ?", Time.current).find_each(&:enqueue)
    end
  end
end

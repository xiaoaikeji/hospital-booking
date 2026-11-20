module Notifications
  class DeliveryWorker
    include Sidekiq::Job
    sidekiq_options retry: false

    def perform(id = nil)
      return Delivery.run(id, job_id: jid) if id
      pending = Notification.where(status: "pending").where("scheduled_at IS NULL OR scheduled_at <= ?", Time.current)
      interrupted = Notification.where(status: "sending", last_attempt_at: ..10.minutes.ago)
        .where("response_data ->> 'finished_at' IS NULL")
      pending.or(interrupted).find_each(&:enqueue)
    end
  end
end

module Appointments
  class ReconcileDueWorker
    include Sidekiq::Job

    def perform
      pending = Appointment.where(status: "pending_payment")
      payments = pending.where(payment_expires_at: ..Time.current)
        .or(pending.where.not(payment_cancel_requested_at: nil))
        .or(pending.where("payment_data @> ?", { prepay_attempted: true }.to_json))
      refunds = Appointment.where(refund_status: %w[processing approved])
      payments.or(refunds).in_batches do |batch|
        ReconcileWorker.perform_bulk(batch.pluck(:id).map { |id| [ id ] })
      end
    end
  end
end

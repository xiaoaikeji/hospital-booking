module Appointments
  class ReconcileWorker
    include Sidekiq::Job

    def perform(id)
      appointment = Appointment.find_by(id: id)
      return unless appointment

      Payment.new(appointment, source: "job").reconcile! if appointment.pending_payment?
      service = Refunds.new(appointment, source: "job")
      appointment.active_refunds.each do |item|
        service.reconcile!(item.fetch("id")) if item["status"] != "requested"
      end
    end
  end
end

Rails.application.config.to_prepare do
  Rails.application.config.x.payments.receiver = Appointments::PaymentReceiver.new(source: "webhook")
end

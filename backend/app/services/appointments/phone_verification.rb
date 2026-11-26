module Appointments
  module PhoneVerification
    def self.required_for?(user)
      user.verified_mobile.blank? && AppointmentSettings.new.phone_required?
    end
  end
end

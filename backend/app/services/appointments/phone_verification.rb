module Appointments
  module PhoneVerification
    def self.required_for?(user, settings: nil)
      user.verified_mobile.blank? && (settings || AppointmentSettings.new).phone_required?
    end
  end
end

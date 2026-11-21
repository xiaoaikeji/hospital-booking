module Appointments
  module PhoneVerification
    def self.required_for?(user)
      user.verified_mobile.blank? && MiniProgramLoginSettings.new("appointment").phone_required?
    end
  end
end

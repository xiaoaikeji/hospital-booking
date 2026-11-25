module Appointments
  class SavePatientOnCreation
    # The creator returns [appointment, newly_created], with false for an idempotent replay.
    # A rejected creation returns nil or raises. Both writes belong to the creation transaction.
    def self.call(user:, save_patient:, request: nil)
      Patient.transaction(requires_new: true) do
        appointment, newly_created = yield
        raise ActiveRecord::Rollback unless appointment && appointment.persisted?
        raise ActiveRecord::RecordNotFound unless appointment.user_id == user.id

        if newly_created == true && save_patient == true && appointment.patient_id.nil?
          patient = user.patients.create!(name: appointment.patient_name, gender: appointment.patient_gender, age: appointment.patient_age)
          appointment.update!(patient_id: patient.id)
          patient.record_change!("create", request: request, details: { fields: Patient::PROFILE_FIELDS })
        end

        appointment
      end
    end
  end
end

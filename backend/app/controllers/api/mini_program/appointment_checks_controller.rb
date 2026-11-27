module Api
  module MiniProgram
    class AppointmentChecksController < BaseController
      def show
        doctor_id, day, time_slot, mode, start_time, end_time =
          params.expect(:doctor_id, :date, :time_slot, :mode, :start_time, :end_time)
        date = parse_date(day)
        settings = AppointmentSettings.new
        bookable = false
        if date && doctor_id.to_s.match?(/\A[1-9][0-9]*\z/) && Doctor.current.enabled.exists?(id: doctor_id)
          calendar = ScheduleCalendar.new([ doctor_id.to_i ], date..date, settings: settings)
          bookable = calendar.bookable_selection?(doctor_id.to_i, date, time_slot: time_slot, mode: mode, start_time: start_time, end_time: end_time)
        end

        render json: {
          bookable: bookable,
          booking_phone_required: Appointments::PhoneVerification.required_for?(@user, settings: settings),
          booking_symptoms_required: settings.enabled?("require_booking_remark")
        }
      end

      private

      def parse_date(value)
        Date.iso8601(value) if value.to_s.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
      rescue Date::Error
        nil
      end
    end
  end
end

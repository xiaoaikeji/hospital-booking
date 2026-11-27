module Api
  module MiniProgram
    class DoctorsController < BaseController
      include BookingDirectory
      include Pagy::Method

      skip_before_action :require_session

      def index
        doctors = booking_doctor_scope
        query = params[:q].strip.presence if params[:q].is_a?(String)
        doctors = doctors.named_like(query) if query

        if (department_id = params[:department_id]).present?
          doctors = booking_department_ids.include?(department_id) ? doctors.in_department(department_id) : doctors.none
        end

        pagination, rows = pagy(:offset, doctors.by_fee(params[:sort]).ordered, limit: 20)
        render json: { doctors: serialize_booking_doctors(rows), next_page: pagination.next }
      end
    end
  end
end

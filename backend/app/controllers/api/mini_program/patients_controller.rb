module Api
  module MiniProgram
    class PatientsController < BaseController
      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, "patient_not_found", "未找到该就诊人")
      end

      def index
        render json: { patients: @user.patients.order(:id).map { |patient| profile_json(patient) } }
      end

      def show
        render json: profile_json(find_patient)
      end

      def update
        with_current_user do
          @patient = find_patient
          attributes = params.expect(patient: Patient::PROFILE_FIELDS.map(&:to_sym))
          @patient.update!(attributes.slice(*Patient::PROFILE_FIELDS))
          fields = Patient::PROFILE_FIELDS & @patient.saved_changes.keys
          @patient.record_change!("update", request: request, details: { fields: fields }) if fields.any?
        end
        render json: profile_json(@patient)
      rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid
        record_failure("update", "invalid_profile")
        render_error(:unprocessable_content, "invalid_patient", "请核对就诊人姓名、性别和年龄")
      rescue ActiveRecord::StatementInvalid
        record_failure("update", "write_failed")
        render_error(:service_unavailable, "patient_unavailable", "就诊人资料暂时无法保存，请重试")
      end

      def destroy
        with_current_user do
          @patient = find_patient
          @patient.destroy!
          @patient.record_change!("remove", request: request)
        end
        head :no_content
      rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid
        record_failure("remove", "write_failed")
        render_error(:service_unavailable, "patient_unavailable", "就诊人暂时无法移除，请重试")
      end

      private

      def find_patient = @user.patients.find(params[:id])

      def profile_json(patient)
        patient.slice(*Patient::PROFILE_FIELDS).merge(id: patient.id.to_s)
      end

      def record_failure(action, reason)
        @patient&.record_change!(action, request: request, status: "failed", details: { reason: reason })
      rescue ActiveRecord::ActiveRecordError
        Rails.logger.warn("Patient change audit could not be written")
      end
    end
  end
end

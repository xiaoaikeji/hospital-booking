module Api
  module MiniProgram
    class AppointmentsController < BaseController
      INDEX_FIELDS = %i[order_no doctor_name department_name patient_name appointment_date slot_label status].freeze
      DETAIL_FIELDS = %i[patient_mobile patient_gender patient_age paid_amount_cents hospital_snapshot remark].freeze

      def index
        records = @user.appointments.current.newest_first
        render json: { appointments: records.map { |record| summary(record) } }
      end

      def show
        record = @user.appointments.current.find_by(order_no: params[:order_no])
        return render_error(:not_found, "appointment_not_found", "暂无该预约记录") unless record

        render json: summary(record).merge(record.slice(*DETAIL_FIELDS), patient_sex: record.patient_sex)
      end

      def create
        attributes = params.expect(appointment: %i[
          idempotency_key doctor_id department_id date time_slot mode start_time end_time
          patient_id patient_name patient_gender patient_age patient_mobile remark save_patient confirm_same_name
        ]).to_h
        result = with_current_user do
          outcome = Appointments::Create.new(user: @user, app: @app, attributes: attributes).call
          record_creation!(target: outcome.appointment) if outcome.outcome == "created"
          outcome
        end

        render json: { order_no: result.appointment.order_no, outcome: result.outcome },
          status: result.outcome == "created" ? :created : :ok
      rescue Appointments::Create::Rejected => error
        record_failure(error.code)
        render_error(:unprocessable_content, error.code, error.message)
      rescue ActionController::ParameterMissing
        record_failure(:invalid_request)
        render_error(:bad_request, "invalid_request", Appointments::Create::MESSAGES.fetch(:invalid_request))
      rescue ActiveRecord::RecordNotUnique
        # A rare order-number collision rolls back the whole write before retrying.
        attempts = (attempts || 0) + 1
        retry if attempts < 3
        unavailable
      rescue ActiveRecord::ActiveRecordError
        unavailable
      end

      private

      def summary(record)
        record.slice(*INDEX_FIELDS).merge(fee: record.fee_in_yuan, status_label: record.status_label)
      end

      def unavailable
        record_failure(:write_failed)
        render_error(:service_unavailable, "appointment_unavailable", "预约暂时无法确认，请重试")
      end

      def record_failure(reason)
        record_creation!(status: "failed", reason: reason)
      rescue ActiveRecord::ActiveRecordError
        Rails.logger.warn("Appointment creation audit could not be written")
      end

      def record_creation!(target: nil, status: "success", reason: nil)
        Log.record!(action: "appointment.create", category: "booking", source: "user", actor: @user, target: target,
          status: status, correlation_id: request.request_id, details: { order_no: target&.order_no, reason: reason&.to_s }.compact)
      end
    end
  end
end

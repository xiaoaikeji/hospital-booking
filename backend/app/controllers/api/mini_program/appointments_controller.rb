module Api
  module MiniProgram
    class AppointmentsController < BaseController
      INDEX_FIELDS = %i[order_no doctor_name department_name patient_name appointment_date slot_label status].freeze
      DETAIL_FIELDS = %i[patient_mobile patient_gender patient_age paid_amount_cents hospital_snapshot remark].freeze
      before_action :load_appointment, except: %i[index create]

      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, "appointment_not_found", "暂无该预约记录")
      end
      rescue_from Appointment::InvalidOperation do |error|
        render_error(:unprocessable_content, "appointment_operation_unavailable", error.message)
      end

      def index
        records = @user.appointments.current.newest_first
        render json: { appointments: records.map { |record| summary(record) } }
      end

      def show
        render json: detail(@appointment)
      end

      def create
        attributes = params.expect(appointment: %i[
          idempotency_key doctor_id department_id date time_slot mode start_time end_time
          patient_id patient_name patient_gender patient_age patient_mobile remark save_patient confirm_same_name
        ]).to_h
        result = with_current_user do
          outcome = Appointments::Create.new(user: @user, app: @app, identity: @identity, attributes: attributes).call
          record_creation!(target: outcome.appointment) if outcome.outcome == "created"
          outcome
        end

        render json: { order_no: result.appointment.order_no, outcome: result.outcome },
          status: result.outcome == "created" ? :created : :ok
      rescue Appointments::Create::Rejected => error
        record_failure(error.code)
        render_error(:unprocessable_content, error.code, error.message)
      rescue Payments::Error, WechatPaySettings::Invalid
        record_failure(:payment_unavailable)
        render_error(:service_unavailable, "payment_unavailable", "微信支付暂不可用，请稍后重试")
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

      def checkout
        service = with_current_user do
          load_appointment
          payment_service
        end
        unless original_payer?(@appointment)
          return render_error(:unprocessable_content, "original_payment_app_required", "请在原预约小程序继续支付")
        end

        payment_params = service.checkout(app: @app, identity: @identity, client_ip: request.remote_ip)
        render json: { payment_no: @appointment.payment_no, payment_params: payment_params }
      rescue Payments::Error, WechatPaySettings::Invalid
        render_error(:service_unavailable, "payment_unavailable", "暂时无法调起支付，请查看预约结果后重试")
      end

      def check_payment
        payment_service.reconcile!
        render json: detail(@appointment)
      end

      def cancel
        service = with_current_user do
          load_appointment
          payment_service.tap(&:request_cancel!)
        end
        service.reconcile!
        render json: detail(@appointment)
      end

      def return_booking
        input = params.expect(refund: [ :idempotency_key ])
        service, id = with_current_user do
          load_appointment
          service = Appointments::Refunds.new(@appointment, source: "user", actor: @user, request: request)
          [ service, service.request!(kind: "cancel", key: input[:idempotency_key]) ]
        end
        service.reconcile!(id)
        render json: detail(@appointment)
      end

      private

      def load_appointment
        @appointment = @user.appointments.current.find_by!(order_no: params[:order_no])
      end

      def payment_service = Appointments::Payment.new(@appointment, source: "user", actor: @user, request: request)

      def original_payer?(record)
        record.payer_user_id == @user.id && record.payment_appid == @app.appid && record.payment_data["openid"] == @identity.openid
      end

      def summary(record)
        record.slice(*INDEX_FIELDS).merge(
          fee: record.fee_in_yuan, status_label: record.status_label, refund_status: record.refund_status,
          refund_label: record.refund_label, payment_status: record.payment_status, payment_closing: record.payment_closing?,
          payment_checking: record.payment_checking?, payment_started: record.payment_data["prepay_attempted"] == true,
          payment_expires_at: record.payment_expires_at&.iso8601,
          can_pay: record.pending_payment? && !record.payment_closing? && !record.payment_checking? && original_payer?(record)
        )
      end

      def detail(record)
        summary(record).merge(record.slice(*DETAIL_FIELDS), patient_sex: record.patient_sex,
          server_time: (Time.current.to_r * 1000).to_i, paid: record.paid_in_yuan,
          can_return: record.patient_can_return?, can_cancel: record.pending_payment? && !record.payment_closing?,
          original_payment_app: original_payer?(record), refunds: record.refund_items.map { |item| refund_summary(item) })
      end

      def refund_summary(item)
        status = item.fetch("status")
        no_charge = item["amount_cents"] == 0 && item["kind"] == "cancel"
        {
          id: item.fetch("id"), kind: item.fetch("kind"), status: status,
          status_label: (no_charge && status == "succeeded" ? "已退号" : Appointment::REFUND_ITEM_LABELS.fetch(status)),
          amount: (Appointment.cents_in_yuan(item["amount_cents"]) if item["amount_cents"] && !no_charge),
          cash: (Appointment.cents_in_yuan(item["payer_refund_cents"]) unless item["payer_refund_cents"].nil?),
          reason: item["reason"], review_note: item["review_note"], refunded_at: item["refunded_at"]
        }
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

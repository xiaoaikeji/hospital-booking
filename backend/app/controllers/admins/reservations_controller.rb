module Admins
  class ReservationsController < BaseController
    PERIODS = { "today" => "今日", "tomorrow" => "明日", "week" => "近7天" }.freeze

    skip_before_action :refresh_storage_configuration
    before_action :require_directory_editor!, except: %i[index show]
    before_action :load_reservation, except: :index

    rescue_from Appointment::InvalidOperation do |error|
      redirect_to reservation_path, alert: error.message, status: :see_other
    end

    def index
      @filters = list_filters
      @pagy, @reservations = pagy(:offset, filtered_appointments, limit: 20)
      @list_context = @filters.merge(page: @pagy.page)
    end

    def show
      @list_context = list_filters.merge(params.permit(:page).to_h.symbolize_keys)
      @payment_cancellation = @reservation.payment_data["staff_cancellation"]
      @cancelling_admin = Admin.find_by(id: @payment_cancellation["admin_id"]) if @payment_cancellation
    end

    def cancel_pending_payment
      input = params.expect(payment_cancellation: [ :reason ])
      service = Appointments::Payment.new(@reservation, source: "admin", actor: current_admin, request: request)
      service.request_cancel!(reason: input[:reason])
      service.reconcile!

      notice = case @reservation.payment_status
      when "closed" then "待支付预约已取消"
      when "paid" then "微信已确认收款，原预约已保留，请使用「医院退号」办理退款"
      else "取消申请已受理，正在核实微信支付结果"
      end
      redirect_to reservation_path, notice: notice, status: :see_other
    end

    def complete
      refund_service.complete_visit!
      redirect_to reservation_path, notice: "已登记就诊", status: :see_other
    end

    def return_booking
      request_refund("cancel")
    end

    def refund_difference
      request_refund("admin_refund")
    end

    def review_refund
      input = params.expect(refund: %i[decision note])
      service = refund_service
      service.review!(params[:refund_record_id], decision: input[:decision], note: input[:note])
      service.reconcile!(params[:refund_record_id]) if input[:decision] == "approve"
      redirect_to reservation_path, notice: "审核结果已保存", status: :see_other
    end

    def sync_refund
      refund_service.sync!(params[:refund_record_id])
      redirect_to reservation_path, notice: "已核对微信退款状态", status: :see_other
    end

    private

    def load_reservation
      @reservation = Appointment.current.find_by!(order_no: params[:order_no])
    end

    def request_refund(kind)
      input = params.expect(refund: %i[idempotency_key reason amount])
      service = refund_service
      id = service.request!(kind: kind, key: input[:idempotency_key], reason: input[:reason], amount: input[:amount])
      service.reconcile!(id)
      redirect_to reservation_path, notice: "申请已保存", status: :see_other
    end

    def refund_service = Appointments::Refunds.new(@reservation, source: "admin", actor: current_admin, request: request)
    def reservation_path = admins_reservation_path(@reservation.order_no, list_filters.merge(params.permit(:page).to_h.symbolize_keys))

    def list_filters
      {
        period: params[:period].presence_in(PERIODS.keys),
        q: (params[:q].strip.first(40).presence if params[:q].is_a?(String))
      }.compact
    end

    def filtered_appointments
      records = Appointment.current.newest_first
      today = Date.current
      dates = case @filters[:period]
      when "today" then today
      when "tomorrow" then today + 1
      when "week" then (today - 6)..today
      end
      records = records.where(appointment_date: dates) if dates
      if (order_no = @filters[:q])
        return records.none unless /\A[0-9]{1,20}\z/.match?(order_no)

        records = records.where("order_no LIKE ?", "%#{order_no}%")
      end
      records
    end
  end
end

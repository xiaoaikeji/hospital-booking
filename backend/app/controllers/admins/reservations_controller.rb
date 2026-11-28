module Admins
  class ReservationsController < BaseController
    PERIODS = { "today" => "今日", "tomorrow" => "明日", "week" => "近7天" }.freeze

    skip_before_action :refresh_storage_configuration
    before_action :require_directory_editor!, except: %i[index show]
    before_action :load_reservation, except: :index

    rescue_from Appointment::InvalidOperation do |error|
      record_rejected_operation
      redirect_to reservation_path, alert: error.message, status: :see_other
    end

    def index
      @filters = list_filters
      @department_options = Department.where(id: Appointment.current.select(:department_id)).order(:name, :id).pluck(:id, :name).to_h
      dates = @filters[:date_range] ? list_date_range(@filters[:date_range]) : legacy_period
      @date_range = @filters[:date_range] || (dates && [ dates.begin, dates.end ].uniq.join(" – "))
      time_filter = ReservationTimeFilter.new(filtered_appointments(dates))
      @time_options = time_filter.options(@filters[:booking_time])
      @pagy, @reservations = pagy(:offset, time_filter.matching(@filters[:booking_time]), limit: 20)
      @list_context = @filters.merge(page: (@pagy.page if @pagy.page > 1)).compact
    end

    def show
      @list_context = list_filters.merge(params.permit(:page).to_h.symbolize_keys)
      @events = Log.where(target_type: "Appointment", target_id: @reservation.id, category: "booking",
        status: %w[started success], action: Admins::RecordHistoryHelper::APPOINTMENT_EVENTS.keys).order(:created_at, :id)
      items = @reservation.refund_items
      @refund_by_id = items.index_by { |item| item["id"] }.except(nil)
      admin_ids = items.filter_map { |item| item["requested_by_id"] if item["requested_by_type"] == "Admin" }
      admin_ids.concat(items.filter_map { |item| item["reviewed_by_admin_id"] })
      @refund_admins = Admin.where(id: admin_ids.uniq).index_by(&:id)
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
      input = params.expect(refund: %i[decision note confirmed_available])
      service = refund_service
      service.review!(params[:refund_record_id], decision: input[:decision], note: input[:note],
        confirmed_available: input[:confirmed_available])
      service.reconcile!(params[:refund_record_id]) if input[:decision] == "approve"
      redirect_to reservation_path, notice: "审核结果已保存", status: :see_other
    end

    def sync_refund
      refund_service.sync!(params[:refund_record_id])
      redirect_to reservation_path, notice: "已核对微信退款状态", status: :see_other
    end

    private

    def record_rejected_operation
      event = { "review_refund" => "refund_review", "return_booking" => "hospital_refund",
        "refund_difference" => "hospital_refund", "complete" => "complete",
        "cancel_pending_payment" => "payment_close_requested" }[action_name]
      return unless event

      details = case action_name
      when "refund_difference" then { kind: "admin_refund" }
      when "return_booking" then { kind: "cancel" }
      when "review_refund"
        item = @reservation.refund_items.find { |row| row["id"].to_s == params[:refund_record_id] }
        item ? { refund_record_id: item["id"], refund_no: item["refund_no"], kind: item["kind"] } : {}
      else {}
      end
      @reservation.record_event!(event, source: "admin", actor: current_admin, request: request, status: "failed", details: details)
    end

    def load_reservation
      @reservation = Appointment.current.find_by!(order_no: params[:order_no])
    end

    def request_refund(kind)
      input = params.expect(refund: %i[idempotency_key reason amount confirmed_available])
      service = refund_service
      id = service.request!(kind: kind, key: input[:idempotency_key], reason: input[:reason], amount: input[:amount],
        confirmed_available: input[:confirmed_available])
      service.reconcile!(id)
      redirect_to reservation_path, notice: "医院退款处理结果已更新", status: :see_other
    end

    def refund_service = Appointments::Refunds.new(@reservation, source: "admin", actor: current_admin, request: request)
    def reservation_path = admins_reservation_path(@reservation.order_no, list_filters.merge(params.permit(:page).to_h.symbolize_keys))

    def list_filters
      date_range = params[:date_range].presence if params[:date_range].is_a?(String)
      refund_status = params[:refund_status].presence_in(Appointment::REFUND_LABELS.keys - [ "none" ])
      refund_status ||= "requested" if params[:tab] == "refund_reviews"
      {
        booking_time: (params[:booking_time] if ReservationTimeFilter.valid?(params[:booking_time])),
        period: (params[:period].presence_in(PERIODS.keys) unless date_range),
        date_range: date_range,
        status: params[:status].presence_in(Appointment::STATUS_LABELS.keys),
        refund_status: refund_status,
        department_id: (params[:department_id].to_i if params[:department_id].is_a?(String) && params[:department_id].match?(/\A[1-9]\d{0,17}\z/)),
        q: (params[:q].strip.first(40).presence if params[:q].is_a?(String))
      }.compact
    end

    def legacy_period
      today = Date.current
      case @filters[:period]
      when "today" then today..today
      when "tomorrow" then today.tomorrow..today.tomorrow
      when "week" then (today - 6)..today
      end
    end

    def filtered_appointments(dates)
      records = Appointment.current.newest_first
      records = records.where(appointment_date: dates) if dates
      records = records.where(@filters.slice(:status, :department_id))
      if @filters[:refund_status] == "requested"
        records = records.where("appointments.refund_data @> ?", { items: [ { status: "requested" } ] }.to_json)
      elsif @filters[:refund_status]
        records = records.where(refund_status: @filters[:refund_status])
      end
      if (order_no = @filters[:q])
        records = if /\A[0-9]{1,20}\z/.match?(order_no)
          records.where("appointments.order_no LIKE ?", "%#{order_no}%")
        else
          records.none
        end
      end
      records
    end
  end
end

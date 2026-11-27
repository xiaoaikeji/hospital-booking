module Admins
  class ReservationsController < BaseController
    PERIODS = { "today" => "今日", "tomorrow" => "明日", "week" => "近7天" }.freeze

    skip_before_action :refresh_storage_configuration

    def index
      @filters = list_filters
      @pagy, @reservations = pagy(:offset, filtered_appointments, limit: 20)
      @list_context = @filters.merge(page: @pagy.page)
    end

    def show
      @reservation = Appointment.current.find_by!(order_no: params[:order_no])
      @list_context = list_filters.merge(params.permit(:page).to_h.symbolize_keys)
    end

    private

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

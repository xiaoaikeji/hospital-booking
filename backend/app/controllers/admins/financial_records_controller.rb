module Admins
  class FinancialRecordsController < BaseController
    before_action :require_financial_access!

    def index
      @refunds = request.path_parameters[:kind] == "refunds"
      @filters = params.permit(:date_range, :q, :status).to_h.symbolize_keys.compact_blank
      @filters.delete(:status) unless @refunds && Appointment::REFUND_ITEM_LABELS.key?(@filters[:status])
      rows = Appointment.current.where(payment_channel: "wechat_jsapi", payment_status: "paid")
      if @refunds
        # Expand before filtering/counting so each row (including page boundaries) is one refund.
        rows = rows.joins("CROSS JOIN LATERAL jsonb_array_elements(appointments.refund_data->'items') WITH ORDINALITY AS refunds(item, ordinal)")
          .select("appointments.id, appointments.order_no, item, ordinal, NULLIF(item->>'created_at', '')::timestamptz AS recorded_at")
        rows = rows.where("item->>'status' = ?", @filters[:status]) if @filters[:status]
        search_columns = ["order_no", "item->>'refund_no'"]
      else
        rows = rows.select(:id, :order_no, :payment_no, :transaction_no, :payable_amount_cents, :paid_amount_cents, "paid_at AS recorded_at")
        search_columns = %w[order_no payment_no transaction_no]
      end
      if @filters[:q]
        term = "%#{Appointment.sanitize_sql_like(@filters[:q].strip)}%"
        rows = rows.where(search_columns.map { |column| "#{column} LIKE :term" }.join(" OR "), term: term)
      end
      records = Appointment.from(rows, :appointments)
      days = list_date_range(@filters[:date_range])
      records = records.where("recorded_at >= ?", days.begin.in_time_zone.utc) if days.begin
      records = records.where("recorded_at < ?", days.end.tomorrow.in_time_zone.utc) if days.end
      records = records.order(Arel.sql("recorded_at DESC NULLS LAST"), id: :desc)
      records = records.order(Arel.sql("ordinal DESC")) if @refunds
      @pagy, @records = pagy(:offset, records, limit: 20)
    end

    private

    def require_financial_access!
      render file: Rails.public_path.join("403.html"), layout: false, status: :forbidden unless current_admin.view_financial_records?
    end
  end
end

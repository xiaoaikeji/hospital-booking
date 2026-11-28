module Admins
  class FinancialRecordsController < BaseController
    before_action :require_financial_access!

    def index
      @refunds = request.path_parameters[:kind] == "refunds"
      @filters = params.permit(:date_range, :q, :status).to_h.symbolize_keys.compact_blank
      @filters.delete(:status) unless @refunds && Appointment::REFUND_ITEM_LABELS.key?(@filters[:status])
      rows = Appointment.wechat_receipts
      if @refunds
        # Guard the function itself as well as pruning bookings before the lateral join.
        items = "appointments.refund_data->'items'"
        rows = rows.where("jsonb_typeof(#{items}) = 'array' AND #{items}->0 IS NOT NULL")
          .joins("CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(#{items}) = 'array' THEN #{items} END) WITH ORDINALITY AS refunds(item, ordinal)")
          .where("jsonb_typeof(item->'id') = 'number' AND item->>'id' ~ '^[1-9][0-9]*$'")
          .where("item->>'kind' IN ('cancel','admin_refund') AND item->>'status' IN (?)", Appointment::REFUND_ITEM_LABELS.keys)
          .where(<<~SQL.squish)
            ((jsonb_typeof(item->'amount_cents') = 'number' AND item->>'amount_cents' ~ '^[0-9]+$')
              OR (item->>'amount_cents' IS NULL AND item->>'kind' = 'cancel' AND item->>'status' <> 'succeeded'))
            AND NOT item @> '{"kind":"cancel","amount_cents":0}'
          SQL
          .select(<<~SQL.squish)
            appointments.id, order_no, item, ordinal,
            CASE WHEN item->>'created_at' ~ '#{Appointment::REFUND_TIME_FORMAT}'
              THEN (jsonb_path_query_first_tz(item, '$.created_at.datetime()', '{}', true) #>> '{}')::timestamptz
            END AS recorded_at
          SQL
        rows = rows.where("item->>'status' = ?", @filters[:status]) if @filters[:status]
        search_columns = ["order_no", "payment_no", "item->>'refund_no'"]
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
      if @pagy.page > @pagy.last
        filters = @filters.merge(page: @pagy.last)
        redirect_to(@refunds ? admins_refund_records_path(filters) : admins_payment_records_path(filters))
      end
    end

    private

    def require_financial_access!
      render file: Rails.public_path.join("403.html"), layout: false, status: :forbidden unless current_admin.view_financial_records?
    end
  end
end

module Admins::ReservationsHelper
  RESERVATION_BADGE_COLORS = {
    "pending_payment" => "warning", "confirmed" => "primary", "cancel_requested" => "warning",
    "completed" => "success", "cancelled" => "secondary"
  }.freeze

  REFUND_BADGE_COLORS = {
    "requested" => "warning", "approved" => "warning", "processing" => "info", "partial" => "success",
    "refunded" => "success", "succeeded" => "success", "rejected" => "secondary", "failed" => "danger"
  }.freeze

  def reservation_badge(record)
    tag.span(record.status_label, class: "badge bg-#{RESERVATION_BADGE_COLORS.fetch(record.status)}-lt")
  end

  def financial_amount(cents) = cents.nil? ? "待核对" : "#{Appointment.cents_in_yuan(cents)} 元"

  def reservation_list_return_path
    filters = params.permit(filters: %i[date_range q status page]).fetch(:filters, {})
    if current_admin.view_financial_records?
      return admins_refund_records_path(filters) if params[:ledger] == "refunds"
      return admins_payment_records_path(filters) if params[:ledger] == "payments"
    end
    admins_reservations_path(@list_context)
  end

  def reservation_refund_badge(status, label)
    tag.span(label, class: "badge bg-#{REFUND_BADGE_COLORS.fetch(status, "secondary")}-lt")
  end

  def reservation_refund_statuses(record)
    statuses = [ record.refund_status ]
    statuses << "requested" if record.refund_items.any? { |item| item["status"] == "requested" }
    statuses.delete("none")
    statuses.delete("requested") if record.status == "cancel_requested"
    statuses.uniq
  end

  def reservation_refund_anchor(item)
    "refund-#{item.fetch('id')}"
  end
end

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

  def refund_cash_label(item)
    case item["status"]
    when "succeeded"
      cash = item["payer_refund_cents"]
      return financial_amount(cash) if cash.is_a?(Integer) && cash >= 0
      return "待核对" if item["amount_cents"].to_i.positive?

      "—"
    when "failed", "rejected" then "未退款"
    else Appointment::REFUND_ITEM_LABELS.fetch(item["status"])
    end
  end

  def refund_time(value)
    return unless value.is_a?(String) && value.match?(/#{Appointment::REFUND_TIME_FORMAT}/)

    DateTime.rfc3339(value).in_time_zone
  rescue Date::Error
    nil
  end

  def reservation_list_return_path
    return admins_refund_records_path(@list_context.fetch(:filters, {})) if @list_context[:ledger] == "refunds"
    return admins_payment_records_path(@list_context.fetch(:filters, {})) if @list_context[:ledger] == "payments"

    admins_reservations_path(@list_context)
  end

  def reservation_refund_badge(status, label)
    tag.span(label, class: "badge bg-#{REFUND_BADGE_COLORS.fetch(status, "secondary")}-lt")
  end

  def reservation_refund_statuses(record)
    statuses = [ record.refund_status ]
    statuses << "requested" if record.readable_refund_items.any? { |item| item["status"] == "requested" }
    statuses.delete("none")
    statuses.delete("requested") if record.status == "cancel_requested"
    statuses.uniq
  end

  def reservation_refund_anchor(item)
    "refund-#{item.fetch('id')}"
  end
end

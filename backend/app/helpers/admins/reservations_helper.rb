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

  def reservation_refund_badge(status, label)
    tag.span(label, class: "badge bg-#{REFUND_BADGE_COLORS.fetch(status)}-lt")
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

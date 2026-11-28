class Appointment < ApplicationRecord
  GENDERS = { 0 => "未知", 1 => "男", 2 => "女" }.freeze
  STATUS_LABELS = {
    "pending_payment" => "待支付", "confirmed" => "待就诊", "cancel_requested" => "退号审核中",
    "completed" => "已完成", "cancelled" => "已取消"
  }.freeze
  PAYMENT_LABELS = { "unpaid" => "待支付", "paid" => "已支付", "closed" => "已关单" }.freeze
  REFUND_LABELS = {
    "none" => "无退款", "requested" => "退款审核中", "approved" => "待发起退款", "rejected" => "审核未通过",
    "processing" => "退款处理中", "partial" => "已部分退款", "refunded" => "已退款", "failed" => "退款失败"
  }.freeze
  REFUND_ITEM_LABELS = REFUND_LABELS.slice("requested", "approved", "rejected", "processing", "failed")
    .merge("succeeded" => "已退款").freeze
  ACTIVE_REFUND_STATES = %w[requested approved processing].freeze
  ACTIVE_BOOKING_STATES = %w[pending_payment confirmed cancel_requested].freeze

  class InvalidOperation < StandardError; end

  belongs_to :user
  belongs_to :doctor
  belongs_to :department
  belongs_to :patient, optional: true
  belongs_to :payer_user, class_name: "User", optional: true
  belongs_to :completed_by_admin, class_name: "Admin", optional: true
  self.filter_attributes += %i[payment_data refund_data]

  scope :current, -> { where(deleted_at: nil) }
  scope :occupying, -> { where(status: [ *ACTIVE_BOOKING_STATES, "completed" ]) }
  scope :awaiting_visit, -> { current.where(status: ACTIVE_BOOKING_STATES) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def notification_deliverable?(event, generation: 0)
    !Appointments::GroupNotice::EVENTS.key?(event) || Appointments::GroupNotice.deliverable?(event, generation: generation)
  end

  def fee_in_yuan = self.class.cents_in_yuan(fee_cents)
  def paid_in_yuan = self.class.cents_in_yuan(paid_amount_cents)
  def patient_sex = GENDERS.fetch(patient_gender)
  def status_label = STATUS_LABELS.fetch(status)
  def refund_label = REFUND_LABELS.fetch(refund_status)
  def pending_payment? = status == "pending_payment" && payment_status == "unpaid"
  def payment_closing? = pending_payment? && (payment_cancel_requested_at.present? || (payment_expires_at && payment_expires_at <= Time.current))
  def payment_checking? = pending_payment? && payment_data["trade_state"].present? && payment_data["trade_state"] != "NOTPAY"

  def refund_items = refund_data.fetch("items", [])
  def active_refunds = refund_items.select { |item| ACTIVE_REFUND_STATES.include?(item.fetch("status")) }
  def succeeded_refunds = refund_items.select { |item| item.fetch("status") == "succeeded" }
  def confirmed_refunded_cash_cents
    amounts = refund_cash_amounts(succeeded_refunds).compact
    amounts.sum if amounts.any?
  end

  def remaining_gross_cents = payable_amount_cents - succeeded_refunds.sum { |item| item.fetch("amount_cents") }
  def available_refund_cents = remaining_gross_cents - active_refunds.sum { |item| item["amount_cents"].to_i }
  def refund_difference_pending? = active_refunds.any? { |item| item["kind"] == "admin_refund" }
  def refund_confirmation_balance(item = nil) = available_refund_cents + item&.fetch("amount_cents").to_i

  def patient_can_return? = status == "confirmed" && payment_status == "paid" && appointment_date >= Date.current
  def return_failed? = status == "cancelled" && refund_items.reverse.find { |item| item["kind"] == "cancel" }&.fetch("status") == "failed"
  def hospital_can_return? = payment_status == "paid" && (status == "confirmed" || return_failed?)
  def price_refund_allowed? = payment_channel == "wechat_jsapi" && payment_status == "paid" && status.in?(%w[confirmed completed])
  def can_complete? = status.in?(%w[confirmed cancel_requested])

  def write_refunds!(items, **attributes)
    active = %w[processing approved requested].find { |state| items.any? { |item| item["status"] == state } }
    succeeded = items.select { |item| item["status"] == "succeeded" }
    gross = succeeded.sum { |item| item.fetch("amount_cents") }
    reserved = items.sum { |item| ACTIVE_REFUND_STATES.include?(item["status"]) ? item["amount_cents"].to_i : 0 }
    cash_amounts = refund_cash_amounts(succeeded)
    cash = cash_amounts.compact.sum
    raise Payments::InvalidResult if gross + reserved > payable_amount_cents || cash > paid_amount_cents

    settled = if payable_amount_cents.positive? && gross == payable_amount_cents
      "refunded"
    elsif gross.positive?
      "partial"
    else
      items.last&.fetch("status").presence_in(%w[rejected failed]) || "none"
    end
    update!(refund_data: { "version" => 1, "items" => items }, refund_status: active || settled,
      refunded_amount_cents: (cash unless cash_amounts.include?(nil)), **attributes)
  end

  def record_event!(action, source:, actor: nil, request: nil, details: {}, status: "success")
    Log.record!(category: "booking", action: "appointment.#{action}", source: source, actor: actor,
      target: self, request: request, status: status, details: details.merge(order_no: order_no))
  end

  def self.generate_order_no
    Time.current.in_time_zone("Asia/Shanghai").strftime("%Y%m%d%H%M%S") + format("%06d", SecureRandom.random_number(1_000_000))
  end

  def self.cents_in_yuan(cents)
    (cents.to_d / 100).to_s("F").sub(/\.?0+\z/, "")
  end

  private

  def refund_cash_amounts(succeeded)
    succeeded.select { |item| item.fetch("amount_cents").positive? }.map { |item| item["payer_refund_cents"] }
  end
end

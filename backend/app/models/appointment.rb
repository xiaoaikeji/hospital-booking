class Appointment < ApplicationRecord
  GENDERS = { 0 => "未知", 1 => "男", 2 => "女" }.freeze
  STATUS_LABELS = {
    "pending_payment" => "待支付", "confirmed" => "待就诊", "cancel_requested" => "退号审核中",
    "completed" => "已完成", "cancelled" => "已取消"
  }.freeze

  belongs_to :user
  belongs_to :doctor
  belongs_to :department
  belongs_to :patient, optional: true
  belongs_to :payer_user, class_name: "User", optional: true

  scope :current, -> { where(deleted_at: nil) }
  scope :confirmed, -> { current.where(status: "confirmed") }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def fee_in_yuan = cents_in_yuan(fee_cents)
  def paid_in_yuan = cents_in_yuan(paid_amount_cents)
  def patient_sex = GENDERS.fetch(patient_gender)
  def status_label = STATUS_LABELS.fetch(status)

  def self.generate_order_no
    Time.current.strftime("%Y%m%d%H%M%S") + format("%06d", SecureRandom.random_number(1_000_000))
  end

  private

  def cents_in_yuan(cents)
    (cents.to_d / 100).to_s("F").sub(/\.?0+\z/, "")
  end
end

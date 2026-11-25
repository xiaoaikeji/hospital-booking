class Schedule < ApplicationRecord
  WEEKDAYS = { 1 => "周一", 2 => "周二", 3 => "周三", 4 => "周四", 5 => "周五", 6 => "周六", 0 => "周日" }.freeze
  DAY_SLOTS = { "AM" => "上午", "PM" => "下午", "FULL" => "全天" }.freeze
  NIGHT_SETTING = "booking_enable_evening"

  belongs_to :doctor

  scope :active, -> { where(is_active: true) }
  scope :weekly, -> { where(end_date: nil) }
  scope :on_date, ->(date) { where(start_date: date, end_date: date) }

  def self.night_enabled?
    values = Setting.where(key: "appointment").pick(:settings)
    ActiveModel::Type::Boolean.new.cast(values&.[](NIGHT_SETTING)) == true
  end

  def weekly? = end_date.nil?
  def night? = time_slot == "NIGHT"
  def off? = time_slot == "OFF"
end

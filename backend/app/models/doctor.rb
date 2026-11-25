class Doctor < DirectoryEntry
  ENABLED_LIMIT = 5
  ENABLED_LOCK_ID = 71_020_022

  has_many :doctor_departments
  has_many :departments, through: :doctor_departments
  scope :current, -> { where(deleted_at: nil) }
  normalizes :main_title, :description, :good_in, :introduction, with: ->(value) { value.strip.presence }

  validates :main_title, length: { maximum: 100, too_long: "最多 100 个字符" }
  validates :fee, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000, message: "请输入有效的挂号费" }
  validate :fee_precision
  validate :within_enabled_limit, if: -> { enabled? && deleted_at.nil? && (new_record? || will_save_change_to_status? || will_save_change_to_deleted_at?) }

  def fee_in_yuan
    fee.to_s("F").sub(/\.?0+\z/, "")
  end

  private

  def fee_precision
    amount = BigDecimal(fee_before_type_cast.to_s, exception: false)
    errors.add(:fee, "挂号费最多保留两位小数") if amount&.finite? && amount != amount.round(2)
  end

  def within_enabled_limit
    # The count and write must share a transaction, including when there are no enabled rows to lock.
    self.class.connection_pool.with_connection do |connection|
      connection.execute("SELECT pg_advisory_xact_lock(#{ENABLED_LOCK_ID})")
    end
    if self.class.current.enabled.where.not(id: id).count >= ENABLED_LIMIT
      errors.add(:status, "开源版最多同时启用 #{ENABLED_LIMIT} 位医生，请先停用一位医生")
    end
  end
end

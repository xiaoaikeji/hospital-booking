class DirectoryEntry < ApplicationRecord
  self.abstract_class = true

  STATUSES = { 1 => "已启用", 0 => "已停用" }.freeze

  has_one_attached :image
  normalizes :name, with: ->(value) { value.strip.presence }
  scope :ordered, -> { order(:sort_order, :id) }
  scope :enabled, -> { where(status: 1) }

  validates :name, presence: { message: "请填写名称" }, length: { maximum: 100, too_long: "最多 100 个字符" }
  validates :status, numericality: { only_integer: true, in: 0..1, message: "请选择有效的状态" }
  validates :sort_order, numericality: { only_integer: true, in: (-2**31)...(2**31), message: "请输入有效的排序整数" }

  def enabled? = status == 1
end

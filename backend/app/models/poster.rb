# 单机构通用海报：背景与原图坐标独立于微信取码和具体报名业务。
class Poster < ApplicationRecord
  MAX_SIDE = 6000
  MAX_PIXELS = 18_000_000
  TARGETS = { "official_account" => "扫码关注公众号", "mini_program" => "扫码打开小程序页面" }.freeze
  FIELDS = %i[name target_kind app_id official_account_qrcode_id page_path page_query qr_x qr_y qr_size].freeze

  has_one_attached :background
  belongs_to :app, optional: true
  belongs_to :official_account_qrcode, optional: true
  normalizes :name, :page_path, :page_query, with: ->(value) { value.to_s.strip }
  validates :name, presence: true, length: { maximum: 120 }
  validates :target_kind, inclusion: { in: TARGETS.keys }, allow_blank: true
  validates :image_width, :image_height, :qr_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_SIDE }
  validates :qr_x, :qr_y, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_SIDE }
  validate :layout_allowed
  validate :target_allowed

  def target_attributes = attributes.symbolize_keys.slice(:target_kind, :app_id, :official_account_qrcode_id, :page_path, :page_query)

  private

  def layout_allowed
    errors.add(:background, "请上传海报底图") unless background.attached?
    return unless [ image_width, image_height, qr_x, qr_y, qr_size ].all? { |n| n.is_a?(Integer) }
    if image_width * image_height > MAX_PIXELS
      errors.add(:background, "图片总像素不能超过 1800 万")
    elsif qr_x + qr_size > image_width || qr_y + qr_size > image_height
      errors.add(:qr_size, "二维码必须完整放在底图内")
    end
  end

  def target_allowed
    return if target_kind.blank?
    Wechat::PosterCode.validate!(**target_attributes)
  rescue Wechat::Error => error
    errors.add(:base, error.message)
  end
end

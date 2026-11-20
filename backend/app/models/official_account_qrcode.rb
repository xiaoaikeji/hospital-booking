class OfficialAccountQrcode < ApplicationRecord
  belongs_to :app
  encrypts :ticket
  attr_readonly :app_id, :name, :scene, :url, :ticket
  normalizes :name, with: ->(value) { value.strip }
  validates :name, presence: true, length: { maximum: 60 }
  validates :scene, format: { with: /\Aqd_[A-Za-z0-9]{12}\z/ }
  validates :ticket, :url, presence: true, on: :create

  def png
    RQRCode::QRCode.new(url).as_png(size: 430, border_modules: 4).to_s
  end
end

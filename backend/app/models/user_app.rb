class UserApp < ApplicationRecord
  belongs_to :user
  belongs_to :app, foreign_key: %i[provider appid], primary_key: %i[provider appid]
  has_one :official_account_fan, dependent: :restrict_with_error
  attr_readonly :provider, :appid, :openid, :user_id
  validates :openid, presence: true, length: { maximum: 150 }
  validate { errors.add(:provider, "与用户平台不一致") if user && user.platform != provider }

  scope :for_app, ->(app) { where(provider: app.provider, appid: app.appid) }
end

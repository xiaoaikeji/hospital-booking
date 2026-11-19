class OpenPlatformAccount < ApplicationRecord
  belongs_to :created_via_app, class_name: "App"
  belongs_to :operator, class_name: "Admin"
  has_many :apps, dependent: :restrict_with_error
  attr_readonly :open_appid, :created_via_app_id
  validates :open_appid, presence: true, length: { maximum: 60 }
  validates :name, presence: true, length: { maximum: 120 }

  def self.bindable_apps
    App.wechat_accounts.joins(:app_authorization).where.not(app_authorizations: {refresh_token: nil})
      .where(open_platform_account_id: nil).where.not(id: OpenPlatformOperation.select(:app_id)).order(:id)
  end
end

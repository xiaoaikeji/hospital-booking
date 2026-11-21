class User < ApplicationRecord
  has_many :user_apps, dependent: :restrict_with_error
  attr_readonly :platform, :user_no
  validates :platform, inclusion: { in: App::PROVIDERS.keys }
  before_validation :generate_user_number, on: :create

  def verified_mobile
    mobile if mobile_verified_at?
  end

  def verify_mobile!(number)
    update!(mobile: number, mobile_verified_at: Time.current)
  end

  def account_profile
    profile = slice(:user_no, :nickname, :avatar_url).merge(login_profile.slice("device_model", "operating_system", "region"))
    profile[:mobile] = verified_mobile if verified_mobile.present?
    profile
  end

  private

  def generate_user_number
    self.user_no ||= SecureRandom.random_number(10_000_000..99_999_999).to_s
  end
end

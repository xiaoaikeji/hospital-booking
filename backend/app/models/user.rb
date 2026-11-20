class User < ApplicationRecord
  has_many :user_apps, dependent: :restrict_with_error
  attr_readonly :platform, :user_no
  validates :platform, inclusion: { in: App::PROVIDERS.keys }
  before_validation :generate_user_number, on: :create

  private

  def generate_user_number
    self.user_no ||= SecureRandom.random_number(10_000_000..99_999_999).to_s
  end
end

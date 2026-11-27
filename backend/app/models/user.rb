class User < ApplicationRecord
  has_many :user_apps, dependent: :restrict_with_error
  has_many :patients, dependent: :restrict_with_error
  has_many :appointments, dependent: :restrict_with_error
  has_one_attached :avatar
  attr_readonly :platform, :user_no
  validates :platform, inclusion: { in: App::PROVIDERS.keys }
  before_validation :generate_user_number, on: :create

  def display_name
    nickname.presence || "#{App::PROVIDERS[platform]}用户#{id}"
  end

  def avatar_initial
    display_name.each_grapheme_cluster.first
  end

  def self.matching_identity(query, verified_mobile: false)
    term = "%#{sanitize_sql_like(query)}%"
    matches = where("users.nickname ILIKE :term OR users.user_no LIKE :term", term: term)
    if verified_mobile
      matches = matches.or(where.not(mobile_verified_at: nil).where("users.mobile LIKE ?", term))
    end
    App::PROVIDERS.each do |platform, label|
      unnamed = where(platform: platform).where("NULLIF(BTRIM(users.nickname), '') IS NULL")
      matches = matches.or(unnamed.where("(? || users.id::text) ILIKE ?", "#{label}用户", term))
    end
    matches
  end

  def verified_mobile
    mobile if mobile_verified_at?
  end

  def verify_mobile!(number)
    update!(mobile: number, mobile_verified_at: Time.current)
  end

  def account_profile
    profile = slice(:user_no, :nickname, :avatar_url).merge(login_profile.slice("device_model", "operating_system", "region"))
    profile[:display_name] = display_name
    profile[:avatar_initial] = avatar_initial
    profile[:mobile] = verified_mobile if verified_mobile.present?
    profile
  end

  private

  def generate_user_number
    self.user_no ||= SecureRandom.random_number(10_000_000..99_999_999).to_s
  end
end

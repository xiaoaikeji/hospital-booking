class App < ApplicationRecord
  PROVIDERS = { "wechat" => "微信", "douyin" => "抖音" }.freeze
  TYPES = { "mini_program" => "小程序", "official_account" => "公众号" }.freeze
  scope :wechat_accounts, -> { where(provider: "wechat") }
  scope :wechat_mini_programs, -> { wechat_accounts.where(app_type: "mini_program") }
  scope :wechat_official_accounts, -> { wechat_accounts.where(app_type: "official_account") }
  belongs_to :open_platform_account, optional: true
  validates :app_type, inclusion: { in: TYPES.keys }
  validates :app_type, exclusion: { in: ["official_account"], message: "抖音仅支持小程序" }, if: -> { provider == "douyin" }
  def code_capable? = provider == "wechat" && app_type == "mini_program"
  def platform_label = "#{PROVIDERS[provider]}#{TYPES[app_type]}"
  def platform_authorized? = provider == "wechat" && app_authorization&.authorized?

  STATUSES = { "active" => "正常", "auditing" => "审核中", "disabled" => "已停用" }.freeze
  has_one :app_authorization, dependent: :restrict_with_error
  has_many :mini_program_releases, dependent: :restrict_with_error
  has_many :mini_program_audits, dependent: :restrict_with_error
  has_many :location_interface_applications, dependent: :restrict_with_error
  has_many :wechat_violations, dependent: :restrict_with_error
  has_many :wechat_notification_events, dependent: :restrict_with_error
  encrypts :appsecret
  attr_readonly :provider, :app_type, :appid
  validates :provider, inclusion: { in: PROVIDERS.keys }
  validates :appid, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/ }, uniqueness: { scope: :provider }
  validates :status, inclusion: { in: STATUSES.keys }

  def accessible? = status != "disabled"
  def display_name = nickname.presence || appid
end

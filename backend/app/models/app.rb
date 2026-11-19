class App < ApplicationRecord
  PROVIDERS = { "wechat" => "微信", "douyin" => "抖音" }.freeze
  STATUSES = { "active" => "正常", "auditing" => "审核中", "disabled" => "已停用" }.freeze
  has_one :app_authorization, dependent: :restrict_with_error
  has_many :mini_program_releases, dependent: :restrict_with_error
  has_many :mini_program_audits, dependent: :restrict_with_error
  encrypts :appsecret
  attr_readonly :provider, :appid
  validates :provider, inclusion: { in: PROVIDERS.keys }
  validates :appid, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/ }, uniqueness: { scope: :provider }
  validates :status, inclusion: { in: STATUSES.keys }

  def accessible? = status != "disabled"
  def display_name = nickname.presence || appid
end

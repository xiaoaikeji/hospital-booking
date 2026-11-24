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
  def wechat_official_account? = provider == "wechat" && app_type == "official_account"
  def platform_label = "#{PROVIDERS[provider]}#{TYPES[app_type]}"

  STATUSES = { "active" => "正常", "auditing" => "审核中", "disabled" => "已停用" }.freeze
  DELETION_REASONS = {
    authorization: "已有微信授权记录，只能停用", users: "已有用户身份记录，只能停用",
    sharing: "请先在小程序用户共享中移除此应用", open_platform: "已有开放平台绑定历史，只能停用",
    links: "该应用还有专属页面配置，请先删除专属配置", notifications: "已有公众号通知配置，只能停用",
    mini_program_releases: "已有代码发布记录，只能停用", mini_program_audits: "已有代码审核记录，只能停用",
    location_interface_applications: "已有地理位置申请记录，只能停用", wechat_violations: "已有微信违规记录，只能停用",
    wechat_notification_events: "已有微信通知记录，只能停用", official_account_callbacks: "已有公众号回调记录，只能停用",
    channel_qrcodes: "已有渠道二维码记录，只能停用", fan_events: "已有粉丝事件记录，只能停用",
    fan_syncs: "已有粉丝同步记录，只能停用", posters: "已有通用海报记录，只能停用",
    platform_creations: "已有开放平台账号创建记录，只能停用", platform_operations: "已有开放平台操作记录，只能停用",
    category_acceptances: "已有服务类目申请记录，只能停用", plugin_updates: "已有微信插件申请记录，只能停用",
    link_operations: "已有公众号关联记录，只能停用"
  }.freeze
  has_many :official_account_callbacks, dependent: :restrict_with_error
  before_destroy :protect_history, prepend: true
  has_one :app_authorization, dependent: :destroy
  has_one :official_account_menu, dependent: :destroy
  has_many :mini_program_releases, dependent: :restrict_with_error
  has_many :mini_program_audits, dependent: :restrict_with_error
  has_many :links, dependent: :restrict_with_error
  has_many :location_interface_applications, dependent: :restrict_with_error
  has_many :wechat_violations, dependent: :restrict_with_error
  has_many :wechat_notification_events, dependent: :restrict_with_error
  encrypts :appsecret, :callback_token, :callback_encoding_aes_key
  validates :wechat_original_id, format: { with: /\Agh_[a-zA-Z0-9_]{1,64}\z/ }, uniqueness: true, allow_nil: true
  attr_readonly :provider, :app_type, :appid
  validates :provider, inclusion: { in: PROVIDERS.keys }
  validates :appid, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/ }, uniqueness: { scope: :provider }
  validates :status, inclusion: { in: STATUSES.keys }

  def accessible? = status != "disabled"
  def display_name = nickname.presence || appid

  private

  def protect_history
    blocker = deletion_blocker
    return unless blocker

    errors.add(:base, blocker)
    throw :abort
  end

  def deletion_blocker
    return DELETION_REASONS[:authorization] if app_authorization&.recorded?
    return DELETION_REASONS[:users] if UserApp.for_app(self).exists?
    return DELETION_REASONS[:sharing] if code_capable? && MiniProgramLoginSettings.trusted_group(appid)
    return DELETION_REASONS[:open_platform] if open_platform_account_id?
    return DELETION_REASONS[:links] if links.exists?
    if app_type == "official_account" && Setting.find_by(key: "notification")&.settings&.dig("accounts", appid).present?
      return DELETION_REASONS[:notifications]
    end

    histories = {
      mini_program_releases: mini_program_releases, mini_program_audits: mini_program_audits, location_interface_applications: location_interface_applications,
      wechat_violations: wechat_violations, wechat_notification_events: wechat_notification_events, official_account_callbacks: official_account_callbacks,
      channel_qrcodes: OfficialAccountQrcode.where(app: self), fan_events: OfficialAccountFanEvent.where(app: self),
      fan_syncs: OfficialAccountFanSync.where(app: self), posters: Poster.where(app: self),
      platform_creations: OpenPlatformAccount.where(created_via_app_id: id), platform_operations: OpenPlatformOperation.where(app: self),
      category_acceptances: WechatCategoryAcceptance.where(app_id: id), plugin_updates: WechatPluginUpdate.where(app_id: id),
      link_operations: WechatLinkOperation.where(app_id: id).or(WechatLinkOperation.where(mini_program_id: id))
    }
    history, = histories.find { |_type, rows| rows.exists? }
    DELETION_REASONS.fetch(history) if history
  end
end

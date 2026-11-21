class App < ApplicationRecord
  PROVIDERS = { "wechat" => "微信", "douyin" => "抖音" }.freeze
  TYPES = { "mini_program" => "小程序", "official_account" => "公众号" }.freeze
  scope :wechat_accounts, -> { where(provider: "wechat") }
  scope :wechat_mini_programs, -> { wechat_accounts.where(app_type: "mini_program") }
  scope :wechat_official_accounts, -> { wechat_accounts.where(app_type: "official_account") }
  belongs_to :open_platform_account, optional: true
  after_update :clear_previous_unionids, if: :saved_change_to_open_platform_account_id?
  validates :app_type, inclusion: { in: TYPES.keys }
  validates :app_type, exclusion: { in: ["official_account"], message: "抖音仅支持小程序" }, if: -> { provider == "douyin" }
  def code_capable? = provider == "wechat" && app_type == "mini_program"
  def platform_label = "#{PROVIDERS[provider]}#{TYPES[app_type]}"
  def platform_authorized? = provider == "wechat" && app_authorization&.authorized?

  STATUSES = { "active" => "正常", "auditing" => "审核中", "disabled" => "已停用" }.freeze
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
  encrypts :appsecret
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
    authorization = app_authorization
    authorization&.lock!
    return "已有微信授权记录，只能停用" if authorization&.used?
    return "已有用户身份记录，只能停用" if UserApp.for_app(self).exists?
    return "已绑定开放平台账号，请先解绑" if open_platform_account_id?
    return "该应用还有专属页面配置，请先删除专属配置" if links.exists?
    if app_type == "official_account" && Setting.find_by(key: "notification")&.settings&.dig("accounts", appid).present?
      return "已有公众号通知配置，只能停用"
    end

    histories = {
      "代码发布" => mini_program_releases, "代码审核" => mini_program_audits, "地理位置申请" => location_interface_applications,
      "微信违规" => wechat_violations, "微信通知" => wechat_notification_events, "公众号回调" => official_account_callbacks,
      "渠道二维码" => OfficialAccountQrcode.where(app: self), "粉丝事件" => OfficialAccountFanEvent.where(app: self),
      "粉丝同步" => OfficialAccountFanSync.where(app: self), "通用海报" => Poster.where(app: self),
      "开放平台账号创建" => OpenPlatformAccount.where(created_via_app_id: id), "开放平台操作" => OpenPlatformOperation.where(app: self),
      "服务类目申请" => WechatCategoryAcceptance.where(app_id: id), "微信插件申请" => WechatPluginUpdate.where(app_id: id),
      "公众号关联" => WechatLinkOperation.where(app_id: id).or(WechatLinkOperation.where(mini_program_id: id))
    }
    label, = histories.find { |_title, rows| rows.exists? }
    "已有#{label}记录，只能停用" if label
  end

  def clear_previous_unionids
    UserApp.for_app(self).where.not(unionid: nil).update_all(unionid: nil, updated_at: Time.current)
  end
end

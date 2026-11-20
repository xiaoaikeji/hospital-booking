class Link < ApplicationRecord
  POSITIONS = { "home_banner" => "首页轮播", "profile_menu" => "我的菜单" }.freeze
  TYPES = {
    "none" => "仅展示", "page" => "内部页面", "tab" => "底部 Tab",
    "webview" => "网页", "miniprogram" => "其他小程序", "contact" => "客服"
  }.freeze
  STATUSES = { "active" => "已启用", "disabled" => "已停用" }.freeze
  PAGE_DESTINATIONS = {
    "/pages/booking/doctors" => "专家团队", "/pages/ucenter/appointments" => "预约记录",
    "/pages/ucenter/feedback" => "意见反馈", "/pages/ucenter/hospital" => "医院介绍"
  }.freeze
  TAB_DESTINATIONS = {
    "/pages/index/index" => "首页", "/pages/booking/index" => "预约挂号", "/pages/ucenter/index" => "我的"
  }.freeze
  MINI_PROGRAM_PATH = %r{\A/?[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_-]+)*\z}

  belongs_to :app, optional: true
  has_one_attached :image
  normalizes :name, :url, with: ->(value) { value.strip.presence }
  scope :ordered, -> { order(:sort_order, :id) }

  validates :position, inclusion: { in: POSITIONS.keys, message: "请选择有效的展示位置" }
  validates :name, presence: { message: "请填写名称" }, length: { maximum: 120, too_long: "名称最多 120 个字符" }
  validates :link_type, inclusion: { in: TYPES.keys, message: "请选择有效的点击行为" }
  validates :status, inclusion: { in: STATUSES.keys, message: "请选择有效的状态" }
  validates :sort_order, numericality: { only_integer: true, in: (-2**31)...(2**31), message: "请输入有效的排序整数" }
  validates :url, length: { maximum: 2048, too_long: "链接最多 2048 个字符" }
  validate :supported_app
  validate :banner_image_required
  validate :destination_valid

  def active? = status == "active"
  def banner? = position == "home_banner"
  def item_label = banner? ? "轮播图" : "菜单项"

  private

  def supported_app
    errors.add(:app, "首期支持微信小程序") if app_id && !app&.code_capable?
  end

  def banner_image_required
    errors.add(:image, "请上传轮播图") if banner? && !image.attached?
  end

  def destination_valid
    unless params.is_a?(Hash)
      errors.add(:params, "参数必须是对象")
      return
    end
    if link_type != "miniprogram" && params.any?
      errors.add(:params, "当前点击行为没有页面参数")
    end

    case link_type
    when "none", "contact"
      errors.add(:url, "当前点击行为无需填写链接") if url.present?
    when "page"
      errors.add(:url, "请选择支持的内部页面") unless PAGE_DESTINATIONS.key?(url)
    when "tab"
      errors.add(:url, "请选择底部导航页面") unless TAB_DESTINATIONS.key?(url)
    when "webview"
      errors.add(:url, "请输入业务域名下的 HTTPS 网址（不含端口）") unless webview_url?
    when "miniprogram"
      validate_mini_program_target
    end
  end

  def validate_mini_program_target
    target = params["target_appid"]
    unless target.is_a?(String) && target.match?(/\A[a-zA-Z0-9_-]{1,100}\z/)
      errors.add(:target_appid, "请填写目标微信小程序的 AppID")
    end
    if url.present? && !MINI_PROGRAM_PATH.match?(url)
      errors.add(:url, "请填写目标页面路径，页面参数请单独填写")
    end
    query = params["query"]
    if params.key?("query") && (url.blank? || !query.is_a?(Hash) ||
        !query.all? { |key, value| key.is_a?(String) && key.present? && value.is_a?(String) })
      errors.add(:params, "请填写目标页面路径，并使用不重复的键名，格式如 from=home_banner")
    end
    errors.add(:params, "包含无效的页面参数") if params.except("target_appid", "query").any?
  end

  def webview_url?
    return false unless %r{\Ahttps://[a-z0-9.-]+(?:[/?#]|\z)}i.match?(url.to_s)

    uri = URI.parse(url)
    labels = uri.host.to_s.split(".", -1)
    uri.is_a?(URI::HTTPS) && labels.size >= 2 && labels.last.match?(/[a-z]/i) &&
      labels.all? { |label| WechatPlatform::AppDomains::DNS_LABEL.match?(label) }
  rescue URI::InvalidURIError
    false
  end
end

class WechatViolation < ApplicationRecord
  belongs_to :app
  has_many :appeals, -> { order(appealed_at: :desc, id: :desc) }, class_name: "WechatAppeal", dependent: :restrict_with_exception

  def safe_rule_url
    uri = URI.parse(rule_url.to_s)
    uri.to_s if uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end
end

class Log < ApplicationRecord
  validates :source, :category, :action, :status, presence: true
  def readonly? = persisted?

  # 只传变更字段名和安全结果，不接收请求参数或密钥原值。
  def self.record!(action:, category:, actor: nil, target: nil, details: {}, request: nil, source: "admin", status: "success")
    safe_details = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(details)
    create!(source: source, category: category, action: action, status: status,
      actor_type: actor&.class&.name, actor_id: actor&.id, target_type: target&.class&.name, target_id: target&.id,
      details: safe_details, request_id: request&.request_id, correlation_id: request&.request_id,
      ip_address: request&.remote_ip, user_agent: request&.user_agent&.truncate(2000))
  end
end

class Notification < ApplicationRecord
  belongs_to :subject, polymorphic: true
  attr_readonly :event, :subject_type, :subject_id, :idempotency_key, :payload
  self.filter_attributes += [ :payload, :response_data ]
  STATES = { "pending" => "等待处理", "sending" => "处理中", "sent" => "渠道已接受", "failed" => "失败" }.freeze
  validates :event, :subject_type, :subject_id, presence: true
  validates :status, inclusion: { in: STATES.keys }
  validate do
    messages = payload["messages"] if payload.is_a?(Hash)
    unless payload.is_a?(Hash) && payload["target"].is_a?(Hash) && payload["target"]["channel_type"].in?(%w[wecom_group wechat_official_account]) && messages.is_a?(Array) && messages.any? &&
        messages.all? { |m| m.is_a?(Hash) && m["id"].is_a?(String) && m["id"].present? && m["content"].is_a?(Hash) && supported_message?(m) } &&
        messages.map { |m| m["id"] }.uniq.size == messages.size
      errors.add(:payload, "目标和消息快照无效")
    end
  end

  def supported_message?(message)
    types = payload.dig("target", "channel_type") == "wecom_group" ? %w[text] : %w[text miniprogrampage template]
    return false unless types.include?(message["type"])
    content = message["content"]
    required = { "text" => %w[text], "miniprogrampage" => %w[title appid pagepath thumb_media_id], "template" => %w[template_id data] }.fetch(message["type"])
    required.all? { |field| content[field].present? }
  end

  after_create_commit :enqueue

  def enqueue
    Notifications::DeliveryWorker.perform_async(id)
  rescue RedisClient::Error
    Rails.logger.warn("通知等待定时派发 notification_id=#{id}")
  end

  def messages = payload.fetch("messages")
  def results = response_data.fetch("messages", [])
  def result_for(id) = results.find { |r| r["message_id"] == id } || { "status" => "pending", "attempt_count" => 0 }
  def uncertain? = results.any? { |r| r["status"] == "sending" && r["provider_state"] != "passive_prepared" }
  def passive_prepared? = results.any? { |r| r["provider_state"] == "passive_prepared" }
  def status_label
    return "待核实" if uncertain?
    return "应答已生成" if status == "sending" && passive_prepared?
    STATES.fetch(status)
  end
  def retryable_ids = results.select { |r| r["status"] == "failed" }.map { |r| r["message_id"] }
end

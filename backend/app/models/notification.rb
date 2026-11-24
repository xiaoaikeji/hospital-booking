class Notification < ApplicationRecord
  belongs_to :subject, polymorphic: true
  attr_readonly :event, :subject_type, :subject_id, :idempotency_key, :payload
  self.filter_attributes += [ :payload, :response_data, :error_message ]
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

  def delivery_error(result)
    return result["error_message"] unless result["stage"] == "channel_rejected"

    # Older receipts may have stored the platform's raw error text.
    Notifications.rejection_message(payload.dig("target", "channel_type"), result.dig("response", "errcode"))
  end
  def uncertain? = results.any? { |r| r["status"] == "sending" && r["provider_state"] != "passive_prepared" }
  def passive_prepared? = results.any? { |r| r["provider_state"] == "passive_prepared" }
  def disabled? = messages.all? { |m| result_for(m["id"])["stage"] == "disabled" }
  def partially_skipped?
    results.size == messages.size && results.to_set { |r| r["stage"] } == Set["channel_accepted", "disabled"]
  end
  def delivery_outcome
    return "skipped" if disabled?
    return "partially_skipped" if partially_skipped?
    return "unknown" if uncertain?
    status
  end

  def status_label
    outcome = delivery_outcome
    return "已跳过" if outcome == "skipped"
    return "部分已跳过" if outcome == "partially_skipped"
    return "待核实" if outcome == "unknown"
    return "应答已生成" if status == "sending" && passive_prepared?
    STATES.fetch(status)
  end
  def retryable_ids = results.select { |r| r["status"] == "failed" && r["stage"] != "disabled" }.map { |r| r["message_id"] }
end

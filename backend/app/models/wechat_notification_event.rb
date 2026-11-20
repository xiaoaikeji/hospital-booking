class WechatNotificationEvent < ApplicationRecord
  belongs_to :app
  STATES = { "pending" => "等待发送", "sending" => "发送中", "sent" => "已通知", "failed" => "发送失败",
             "unknown" => "发送结果待核实", "skipped" => "已跳过" }.freeze

  def self.color(status)
    { "sent" => "success", "failed" => "danger", "unknown" => "warning" }.fetch(status, "secondary")
  end

  def notification_deliverable? = WechatPlatform::NotificationSettings.new.enabled?(kind)

  def notification_delivery_finished!(task)
    state = if task.disabled?
      "skipped"
    elsif task.uncertain?
      "unknown"
    else
      task.status
    end
    error_code = task.results.filter_map { |result| result.dig("response", "errcode") }.find(&:nonzero?)
    update!(status: state, error_code: error_code)
  end

  after_create_commit do
    WechatPlatform::NotificationWorker.perform_async(id)
  rescue RedisClient::Error
    Rails.logger.warn("微信通知等待定时派发 event_id=#{id}")
  end
end

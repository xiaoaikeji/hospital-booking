class WechatNotificationEvent < ApplicationRecord
  belongs_to :app
  has_one :delivery_task, as: :subject, class_name: "Notification"
  LABELS = {
    "passed" => "审核通过", "rejected" => "审核未通过", "delayed" => "审核延后",
    "published" => "发布成功", "failed" => "发布失败", "violation" => "新增违规",
    "appeal_1" => "申诉处理中", "appeal_2" => "申诉不通过", "appeal_3" => "申诉通过",
    "category_2" => "类目审核未通过", "category_3" => "类目审核通过"
  }.freeze
  STATES = { "pending" => "等待发送", "sending" => "发送中", "sent" => "已通知", "failed" => "发送失败",
             "unknown" => "发送结果待核实", "skipped" => "已跳过", "interval_skipped" => "发送间隔内已跳过", "partially_skipped" => "部分已跳过" }.freeze

  def self.color(status)
    { "sent" => "success", "failed" => "danger", "unknown" => "warning" }.fetch(status, "secondary")
  end

  # Completed and queued notifications retain their original channel and delivery policy.
  def notification_deliverable?(_event = nil, generation: 0)
    row = Setting.find_by(key: Notifications::WecomSettings::GROUP)
    return false unless Array(row&.settings&.fetch("kinds", [])).include?(kind)
    config = Notifications::WecomSettings.new(row)
    raise Notifications::Error, "企业微信群机器人 Key 无法解密" if config.key_unreadable?
    config.key.present?
  end

  def notification_delivery_finished!(task)
    error_code = task.results.filter_map { |result| result.dig("response", "errcode") }.find(&:nonzero?)
    update!(status: task.delivery_outcome, error_code: error_code)
  end
end

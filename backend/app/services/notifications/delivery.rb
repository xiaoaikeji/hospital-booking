module Notifications
  class Delivery
    def self.run(id, job_id: nil)
      Notification.connection_pool.with_connection do |db|
        lock = "hashtextextended('booking.notification:#{Integer(id)}', 0)"
        return unless db.select_value("SELECT pg_try_advisory_lock(#{lock})")
        begin
          new(Notification.find(id), job_id).run
        ensure
          db.execute("SELECT pg_advisory_unlock(#{lock})")
        end
      end
    end

    def initialize(row, job_id)
      @row, @job_id = row, job_id
    end

    def run
      return unless @row.status == "pending" && (!@row.scheduled_at || @row.scheduled_at <= Time.current)
      if @row.subject.respond_to?(:notification_deliverable?) && !@row.subject.notification_deliverable?
        @row.update!(status: "failed", error_message: "本次通知已关闭，未发送")
        return
      end
      @row.update!(status: "sending", attempt_count: @row.attempt_count + 1, last_attempt_at: Time.current, job_id: @job_id)
      @row.messages.each do |message|
        result = @row.result_for(message["id"])
        next unless result["status"] == "pending"
        # 在外部调用前单独提交。进程中断留下 sending，永不当成未发送重试。
        save_result(message, result.merge("status" => "sending", "attempt_count" => result["attempt_count"].to_i + 1,
          "last_attempt_at" => Time.current.iso8601, "stage" => "request_started", "response" => nil, "error_message" => nil, "provider_state" => nil, "sent_at" => nil))
        begin
          outcome = channel.send_message(message, notification: @row)
          raise HttpConnection::Unavailable unless outcome["status"].in?(%w[sent failed])
          accepted = outcome["status"] == "sent"
          save_result(message, @row.result_for(message["id"]).merge("status" => accepted ? "sent" : "failed",
            "stage" => accepted ? "channel_accepted" : "channel_rejected", "response" => outcome["response"],
            "error_message" => outcome["error_message"],
            "sent_at" => accepted ? Time.current.iso8601 : nil))
        rescue HttpConnection::Unavailable
          save_result(message, @row.result_for(message["id"]).merge("provider_state" => "unknown", "stage" => "awaiting_verification",
            "error_message" => "请求结果待核实，请先核对渠道，系统不会自动补发"))
        rescue Error => error
          save_result(message, @row.result_for(message["id"]).merge("status" => "failed", "stage" => "validation_failed", "error_message" => error.message))
        end
      end
      finish
    end

    private

    def channel
      @channel ||= case @row.payload.dig("target", "channel_type")
      when "wecom_group" then Channels::WecomGroup.new(@row.payload["target"])
      when "wechat_official_account" then Channels::OfficialAccount.new(@row.payload["target"])
      else raise Error, "不支持的通知渠道"
      end
    end

    def save_result(message, result)
      rows = @row.results.reject { |r| r["message_id"] == message["id"] }
      rows << result.merge("message_id" => message["id"])
      @row.update!(response_data: @row.response_data.merge("messages" => rows))
    end

    def finish
      all_sent = @row.messages.all? { |m| @row.result_for(m["id"])["status"] == "sent" }
      status = if all_sent
        "sent"
      elsif @row.uncertain?
        "sending"
      elsif @row.results.any? { |r| r["status"] == "failed" }
        "failed"
      else
        "sending"
      end
      errors = @row.results.filter_map { |r| "#{r['message_id']}：#{r['error_message']}" if r["error_message"].present? }
      @row.update!(status: status, sent_at: all_sent ? Time.current : nil, error_message: errors.join("；").presence)
      subject = @row.subject
      subject.notification_delivery_finished!(@row) if subject.respond_to?(:notification_delivery_finished!)
    end
  end
end

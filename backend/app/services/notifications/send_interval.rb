module Notifications
  module SendInterval
    MAX_MINUTES = 43_200

    def self.normalize(value)
      return if value.nil? || value.is_a?(String) && value.strip.empty?
      number = value.to_s
      unless number.match?(/\A[0-9]{1,5}\z/) && number.to_i <= MAX_MINUTES
        raise FieldError.new("请输入 0～#{MAX_MINUTES} 之间的整数分钟", field: "send_interval")
      end
      number.to_i.nonzero?
    end

    # 调用方在已有的收件人锁内查询并登记任务。事务回滚不会提前占用发送间隔。
    def self.active?(minutes)
      return false unless minutes.to_i.positive?
      yield.where("notifications.created_at > ?", minutes.minutes.ago).exists?
    end
  end
end

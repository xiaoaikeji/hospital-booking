class WechatAppeal < ApplicationRecord
  belongs_to :wechat_violation
  STATUSES = { 1 => "正在处理", 2 => "申诉不通过", 3 => "申诉通过", 4 => "申诉已撤销" }.freeze
end

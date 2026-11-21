class WechatViolation < ApplicationRecord
  belongs_to :app
  has_many :appeals, -> { order(appealed_at: :desc, id: :desc) }, class_name: "WechatAppeal", dependent: :restrict_with_exception
end

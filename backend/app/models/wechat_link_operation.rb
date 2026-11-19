class WechatLinkOperation < ApplicationRecord
  belongs_to :app

  def awaiting_verification?(remote_status)
    state == "started" || (state == "accepted" && !observed?(remote_status))
  end

  def observed?(remote_status)
    return remote_status.nil? if action == "delete"
    remote_status.present? && remote_status != previous_status
  end
end

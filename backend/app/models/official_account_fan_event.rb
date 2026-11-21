class OfficialAccountFanEvent < ApplicationRecord
  belongs_to :app
  encrypts :openid

  def self.receive!(app, openid, event, seconds, qr_scene)
    digest = Digest::SHA256.hexdigest([openid, event, seconds, qr_scene].to_json)
    record = find_or_create_by!(app: app, digest: digest) do |row|
      row.assign_attributes(openid: openid, event: event, occurred_at: Time.zone.at(seconds), qr_scene: qr_scene)
    end
    # 微信只有在入队成功后才收到 success。入队前进程中断时，重发会复用已保存的回调。
    raise Wechat::Error unless WechatPlatform::FanEventWorker.perform_async(record.id)
  end
end

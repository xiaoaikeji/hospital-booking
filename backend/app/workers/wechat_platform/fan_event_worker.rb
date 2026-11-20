module WechatPlatform
  class FanEventWorker
    include Sidekiq::Job
    sidekiq_options retry: 3

    def perform(id)
      record = OfficialAccountFanEvent.find_by(id: id)
      return unless record
      app = record.app
      if app.platform_authorized?
        OfficialAccountFans.new(app).event!(record.openid, record.event, record.occurred_at.to_i, record.qr_scene)
      end
      record.delete
    end
  end
end

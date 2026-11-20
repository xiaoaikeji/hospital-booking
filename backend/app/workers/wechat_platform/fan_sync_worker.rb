module WechatPlatform
  class FanSyncWorker
    include Sidekiq::Job
    sidekiq_options retry: 3

    def perform(id)
      run = OfficialAccountFanSync.find_by(id: id)
      OfficialAccountFans.new(run.app).sync!(run) if run
    end
  end
end

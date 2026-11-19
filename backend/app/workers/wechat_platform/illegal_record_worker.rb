module WechatPlatform
  class IllegalRecordWorker
    include Sidekiq::Job
    sidekiq_options retry: false

    def perform(app_id = nil)
      return unless IllegalRecords.enabled?
      if app_id
        app = App.wechat_mini_programs.find_by(id: app_id)
        IllegalRecords.sync(app, appeals_only: true) if app
      else
        App.wechat_mini_programs.joins(:app_authorization).where.not(app_authorizations: { refresh_token: nil }).find_each do |app|
          IllegalRecords.sync(app)
        end
      end
    end
  end
end

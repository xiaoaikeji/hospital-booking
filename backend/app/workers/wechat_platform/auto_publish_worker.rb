module WechatPlatform
  class AutoPublishWorker
    include Sidekiq::Job

    def perform(round_id)
      audit = MiniProgramAudit.find_by(id: round_id)
      MiniProgramReleaseService.new(audit.app).publish!(audit, automatic: true) if audit
    end
  end
end

module WechatPlatform
  class AuditPollWorker
    include Sidekiq::Job

    def perform
      MiniProgramAudit.pending.or(MiniProgramAudit.where(publication: "publish_unknown")).distinct.pluck(:app_id).each do |app_id|
        AuditEventWorker.perform_async(app_id)
      end
      latest = MiniProgramAudit.accepted_or_uncertain.select("MAX(id)").group(:app_id)
      ready = MiniProgramAudit.joins(:mini_program_release).where(id: latest, status: "passed", auto_publish: true, publication: "unpublished")
      ready.where.not(mini_program_releases: { status: "closed" }).find_each do |audit|
        AutoPublishWorker.perform_async(audit.id)
      end
    end
  end
end

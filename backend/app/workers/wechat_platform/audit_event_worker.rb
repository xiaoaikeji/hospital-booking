module WechatPlatform
  class AuditEventWorker
    include Sidekiq::Job

    def perform(app_id, feedback = nil)
      app = App.find_by(id: app_id)
      return unless app&.app_authorization&.authorized?
      rounds = app.mini_program_audits
      active = rounds.pending.or(rounds.where(publication: "publish_unknown"))
      active = active.or(rounds.where(audit_id: feedback.fetch("audit_id"), status: "rejected")) if feedback
      active.find_each do |audit|
        MiniProgramReleaseService.new(app).sync!(audit, event: feedback)
      rescue Error => error
        Rails.logger.warn("微信审核核对 round=#{audit.id} #{error.message}")
      end
    end
  end
end

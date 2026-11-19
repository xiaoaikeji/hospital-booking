module WechatPlatform
  class AuditEventWorker
    include Sidekiq::Job

    def perform(app_id)
      app = App.find_by(id: app_id)
      return unless app&.app_authorization&.authorized?
      app.mini_program_audits.pending.or(app.mini_program_audits.where(publication: "publish_unknown")).find_each do |audit|
        MiniProgramReleaseService.new(app).sync!(audit)
      rescue Error => error
        Rails.logger.warn("微信审核核对 round=#{audit.id} #{error.message}")
      end
    end
  end
end

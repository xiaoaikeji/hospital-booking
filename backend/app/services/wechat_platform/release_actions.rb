module WechatPlatform
  # UI 和写操作共用。调用微信的 Service 在应用锁内重新读取这些条件。
  class ReleaseActions
    attr_reader :app, :release, :round
    def initialize(app, release: nil, round: nil)
      @app, @release, @round = app, release, round
    end

    def authorized? = app.code_capable? && app.platform_authorized?
    def upload? = authorized? && !uncertain_upload? && !uncertain_audit?
    def trial? = authorized? && release&.current_build? && release.status == "uploaded" && release.action_round&.publication != "published"
    def verify_upload? = authorized? && release&.status == "upload_unknown"
    def submit?
      trial? && !uncertain_audit? && (release.effective_audit.nil? || %w[rejected withdrawn].include?(release.effective_audit.status))
    end
    def sync? = authorized? && round && (MiniProgramAudit::PENDING.include?(round.status) || round.publication == "publish_unknown" || round.status == "rejected")
    def resolve? = authorized? && round && (%w[submit_unknown withdraw_unknown].include?(round.status) || round.publication == "publish_unknown")
    def withdraw? = authorized? && latest? && %w[pending delayed].include?(round.status) && !uncertain_audit?
    def change_mode? = withdraw? && open_record?
    def manual_publish? = publishable? && (round.publication == "failed" || (!round.auto_publish? && round.publication == "unpublished"))
    def auto_publish? = publishable? && round.auto_publish? && round.publication == "unpublished"
    def close? = release && !%w[closed upload_unknown].include?(release.status) && release.action_round&.publication != "published"
    def delete? = release&.status == "closed"

    private

    def open_record? = release && release.status != "closed"
    def latest? = round && app.mini_program_audits.accepted_or_uncertain.maximum(:id) == round.id
    def uncertain_upload? = app.mini_program_releases.exists?(status: "upload_unknown")
    def uncertain_audit?
      app.mini_program_audits.where(status: %w[submit_unknown withdraw_unknown]).or(app.mini_program_audits.where(publication: "publish_unknown")).exists?
    end
    def publishable? = authorized? && open_record? && latest? && round.status == "passed" && !uncertain_audit?
  end
end

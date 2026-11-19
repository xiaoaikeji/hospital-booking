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
      upload? && release&.status == "uploaded" && !release.restored_for_id &&
        (release.effective_audit.nil? || %w[rejected withdrawn].include?(release.effective_audit.status)) && !blocked_by_review
    end

    def blocked_by_review
      app.mini_program_audits.where(status: %w[pending delayed]).order(id: :desc).first
    end

    def retry_upload?
      return false unless upload? && release&.status == "upload_failed"
      return false if app.mini_program_releases.exists?(source_release_id: release.id)
      return true unless release.restored_for_id

      source = app.mini_program_releases.find_by(id: release.restored_for_id)
      latest = app.mini_program_releases.where(restored_for_id: release.restored_for_id).maximum(:id)
      latest == release.id && ReleaseActions.new(app, release: source).submit?
    end
    def sync? = authorized? && round && (MiniProgramAudit::PENDING.include?(round.status) || round.publication == "publish_unknown" || round.status == "rejected")
    def resolve? = authorized? && round && (%w[submit_unknown withdraw_unknown].include?(round.status) || round.publication == "publish_unknown")
    def withdraw? = authorized? && latest? && %w[pending delayed].include?(round.status) && !uncertain_audit?
    def change_mode? = open_record? && latest? && %w[pending delayed].include?(round.status) && !uncertain_audit?
    def manual_publish? = publishable? && (round.publication == "failed" || (!round.auto_publish? && round.publication == "unpublished"))
    def auto_publish? = publishable? && round.auto_publish? && round.publication == "unpublished"
    alias_method :resume_auto?, :auto_publish?
    def close? = delete? && open_record? && release.action_round&.publication != "published"
    def delete?
      release && release.status != "upload_unknown" &&
        !app.mini_program_releases.where(status: "upload_unknown").where("previous_build_id = :id OR restored_for_id = :id", id: release.id).exists? &&
        !release.mini_program_audits.where(status: %w[submit_unknown withdraw_unknown]).or(release.mini_program_audits.where(publication: "publish_unknown")).exists?
    end

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

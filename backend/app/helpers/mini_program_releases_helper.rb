module MiniProgramReleasesHelper
  def release_progress_badge(release)
    stage = MiniProgramRelease::STAGE_BY_PROGRESS.fetch(release.progress)
    color = case stage
    when "passed", "published", "uploaded" then "success"
    when "upload_failed", "rejected", "failed", "not_accepted" then "danger"
    when "uploading", "pending", "delayed" then "warning"
    else "secondary"
    end
    tag.span(MiniProgramRelease::STAGES.fetch(stage).first, class: "badge bg-#{color}-lt")
  end

  def release_result_text(release)
    return if %w[published closed].include?(release.progress)
    if release.progress == "uploaded" && release.restored_for_id
      return "为发布记录 ##{release.restored_for_id} 恢复体验版"
    end
    if release.progress == "uploaded"
      pending = WechatPlatform::ReleaseActions.new(release.app, release: release).blocked_by_review
      return "等待 #{pending.version} 的审核结束或撤回" if pending
    end
    round = release.latest_audit
    return round.rejection_reason if round&.status == "rejected" && round.rejection_reason.present?
    return round.delay_reason if round&.status == "delayed" && round.delay_reason.present?
    code = round&.error_code || release.error_code
    return Wechat::BaseClient::Rejected.new(code).message if code
    return "待确认微信是否受理本轮提审" if release.progress == "submit_unknown"
    return "待核对微信体验版" if release.progress == "upload_unknown"
    return "待核对微信线上版本" if release.progress == "publish_unknown"
    return "待确认本轮是否已撤回" if release.progress == "withdraw_unknown"
    return "等待自动发布" if release.progress == "auto_wait"
    return "最新一次提审未受理" if round&.status == "not_accepted"
    return round.auto_publish? ? "审核通过后自动发布" : "审核通过后手动发布" if %w[pending delayed].include?(release.progress)
    return "等待手动发布" if release.progress == "passed" && !round&.auto_publish?
  end

  def release_detail_url(release)
    admins_mini_program_release_path(release, list: @filters.merge(page: @pagy.page))
  end
end

module Admins::AppsHelper
  def wechat_interface_doc(path)
    return if path.blank?
    url = URI.join("https://developers.weixin.qq.com/", path.to_s)
    url.to_s.sub(/\.md\z/, ".html") if url.is_a?(URI::HTTPS) && url.host == "developers.weixin.qq.com" && !url.userinfo
  rescue URI::Error
    nil
  end

  def wechat_profile_quota(info, period)
    used, total = info.values_at("modify_used_count", "modify_quota")
    return if used.nil? && total.nil?
    tag.small("#{period}已改 #{used || '—'} / #{total || '—'} 次", class: "text-secondary")
  end

  def wechat_avatar_url(raw)
    uri = URI.parse(raw.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present? && !uri.userinfo
    return uri.to_s if uri.scheme == "https"
    uri.to_s.sub(/\Ahttp:/, "https:") if uri.host.match?(/(?:\A|\.)q(?:logo|pic)\.cn\z/i)
  rescue URI::InvalidURIError
    nil
  end

  def application_list_context
    if params[:list].is_a?(ActionController::Parameters)
      params[:list].permit(:provider, :app_type, :status, :q, :page).to_h.compact_blank
    elsif controller_name == "apps" && action_name == "index"
      @filters.merge(page: (@pagy.page if @pagy.page > 1)).compact
    else
      {}
    end
  end

  def application_context_params
    context = application_list_context
    context.any? ? { list: context } : {}
  end
end

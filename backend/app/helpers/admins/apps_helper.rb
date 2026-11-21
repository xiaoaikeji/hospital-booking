module Admins::AppsHelper
  def app_direct_qrcode_available?(app)
    app.code_capable? && Wechat::AccessToken.configured?(app)
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

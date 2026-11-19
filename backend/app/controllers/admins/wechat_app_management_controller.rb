module Admins
  class WechatAppManagementController < BaseController
    before_action :require_super_admin!
    before_action :load_wechat_mini_program

    private

    def load_wechat_mini_program
      @app = App.wechat_mini_programs.find(params[:app_id])
    end

    def perform_wechat_change(action, tab:, notice:, details: {})
      raise WechatPlatform::Error, "请先完成该应用的平台授权" unless @app.platform_authorized?
      yield
      WechatPlatform.log!(@app, action.delete_prefix("wechat."), actor: current_admin, request: request, details: details)
      redirect_to admins_app_path(@app, helpers.application_context_params.merge(tab: tab)), notice: notice, status: :see_other
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      WechatPlatform.log!(@app, action.delete_prefix("wechat."), actor: current_admin, request: request, status: "failed",
        details: details.merge(reason: error.message))
      redirect_to admins_app_path(@app, helpers.application_context_params.merge(tab: tab)), alert: error.message, status: :see_other
    end
  end
end

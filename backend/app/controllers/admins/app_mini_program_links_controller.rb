module Admins
  class AppMiniProgramLinksController < WechatAppManagementController
    def create
      service.change!("create", params)
      back("已发出关联申请，请等待微信管理员确认")
    end

    def destroy
      service.change!("delete", params)
      back("微信已确认解除请求")
    end

    def verify
      service.verify!(params)
      back("已登记微信关联核实结果")
    end

    rescue_from WechatPlatform::Error do |error|
      redirect_to tab_path, alert: error.message, status: :see_other
    end

    private

    def managed_app_scope = App.wechat_official_accounts
    def service = WechatPlatform::OfficialAccountLinks.new(@app, actor: current_admin, request: request)
    def tab_path
      context = helpers.application_context_params.merge(params.permit(:links_q, :links_page).to_h)
      admins_app_path(@app, context.merge(tab: "links"))
    end
    def back(message) = redirect_to(tab_path, notice: message, status: :see_other)
  end
end

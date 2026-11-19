module Admins
  class AppCategoriesController < WechatAppManagementController
    def create
      service.add!(params)
      respond_to do |format|
        format.json { flash[:notice] = "服务类目已提交"; render json: { url: tab_path } }
        format.html { redirect_to tab_path, notice: "服务类目已提交", status: :see_other }
      end
    end

    def destroy
      first, second = params[:id].to_s.match(/\A(\d+)-(\d+)\z/)&.captures
      service.remove!(params.merge(first: first, second: second))
      redirect_to tab_path, notice: "服务类目已删除", status: :see_other
    end

    def verify
      service.verify!(params)
      redirect_to tab_path, notice: "已核实服务类目操作", status: :see_other
    end

    rescue_from WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable do |error|
      respond_to do |format|
        format.json { render json: { error: error.message, verify: (tab_path if service.awaiting_verification?) }, status: :unprocessable_content }
        format.html { redirect_to tab_path, alert: error.message, status: :see_other }
      end
    end

    private

    def service = WechatPlatform::AppCategories.new(@app, actor: current_admin, request: request)
    def tab_path = admins_app_path(@app, helpers.application_context_params.merge(tab: "categories"))
  end
end

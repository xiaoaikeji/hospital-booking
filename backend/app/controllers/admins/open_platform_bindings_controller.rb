module Admins
  class OpenPlatformBindingsController < BaseController
    before_action :require_super_admin!
    before_action :load_account

    def create
      app = App.wechat_accounts.find(params[:app_id])
      service(app).bind!(@account)
      redirect_to admins_open_platform_account_path(@account), status: :see_other, notice: "已绑定 #{app.display_name}"
    end

    def destroy
      app = @account.apps.where(provider: "wechat").find(params[:id])
      service(app).unbind!(@account)
      redirect_to admins_open_platform_account_path(@account), status: :see_other, notice: "已解绑 #{app.display_name}"
    end

    rescue_from WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable do |error|
      redirect_to admins_open_platform_account_path(@account), status: :see_other, alert: error.message
    end

    private

    def load_account = @account = OpenPlatformAccount.find(params[:open_platform_account_id])
    def service(app) = WechatPlatform::OpenPlatformService.new(app, actor: current_admin, request: request)
  end
end

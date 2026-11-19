module Admins
  class AppOpenPlatformsController < WechatAppManagementController
    def update
      account = WechatPlatform::OpenPlatformService.new(@app, actor: current_admin, request: request).sync!
      result = account ? "当前绑定 #{account.name}（#{account.open_appid}）" : "当前未绑定开放平台账号"
      redirect_to tab_path, status: :see_other, notice: "已同步，#{result}"
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      redirect_to tab_path, status: :see_other, alert: error.message
    end

    private

    def managed_app_scope = App.wechat_accounts
    def tab_path = admins_app_path(@app, helpers.application_context_params.merge(tab: "open_platform"))
  end
end

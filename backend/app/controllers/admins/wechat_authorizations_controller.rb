module Admins
  class WechatAuthorizationsController < BaseController
    before_action :require_super_admin!

    def create
      @app = App.find(params[:app_id])
      url = WechatPlatform::AuthorizationFlow.new(@app).start!(current_admin, request) do |state|
        api_wechat_authorization_callback_url(state: state)
      end
      redirect_to url, allow_other_host: true, status: :see_other
    end

    def callback
      auth = WechatPlatform::AuthorizationFlow.pending!(params[:state], current_admin, request)
      @app = auth.app
      WechatPlatform::AuthorizationFlow.new(@app).complete!(auth, params[:auth_code], current_admin, request)
      redirect_to admins_app_path(@app), notice: "微信授权已完成"
    end

    rescue_from WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable, ActiveRecord::ActiveRecordError do |error|
      reason = error.is_a?(ActiveRecord::ActiveRecordError) ? "授权记录未保存，请重新发起授权" : error.message
      WechatPlatform.log!(@app, action_name == "create" ? "authorize" : "authorized", actor: current_admin, request: request,
        status: "failed", details: { reason: reason })
      redirect_to(@app ? admins_app_path(@app) : admins_apps_path, alert: reason)
    end
  end
end

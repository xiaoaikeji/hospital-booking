module Admins
  class AppProfilesController < WechatAppManagementController
    def update
      service = WechatPlatform::AppProfile.new(@app)
      case params[:field]
      when "signature"
        value = params[:signature].to_s.strip
        perform_wechat_change("profile_signature", tab: "profile", notice: "简介已提交微信") do
          service.update_signature(value, revision: params[:revision])
        rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable
          flash[:profile_draft] = { app_id: @app.id, signature: value.first(120) }
          raise
        end
      when "head_image"
        perform_wechat_change("profile_head_image", tab: "profile", notice: "头像已提交微信") do
          service.update_head_image(params[:head_image], revision: params[:revision])
        end
      else
        head :bad_request
      end
    end
  end
end

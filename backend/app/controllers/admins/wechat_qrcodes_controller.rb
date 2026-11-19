module Admins
  class WechatQrcodesController < BaseController
    before_action :require_super_admin!

    def show
      app = App.where(provider: "wechat").find(params[:app_id])
      bytes = WechatPlatform::ReleaseQrcode.fetch(app)
      mime = bytes.start_with?("\x89PNG".b) ? "image/png" : "image/jpeg"
      send_data bytes, type: mime, disposition: "inline", filename: "#{app.appid}-release.#{mime == "image/png" ? "png" : "jpg"}"
      response.headers["Cache-Control"] = "private, no-store"
    rescue WechatPlatform::Error, AppConfiguration::Invalid, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      render json: { error: error.message }, status: :unprocessable_content
    end
  end
end

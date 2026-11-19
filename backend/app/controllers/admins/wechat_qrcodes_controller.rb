module Admins
  class WechatQrcodesController < BaseController
    before_action :require_super_admin!

    def refresh
      app = App.wechat_mini_programs.find(params[:app_id])
      trial = app.mini_program_releases.find_by(current_build: true)
      WechatPlatform::ReleaseQrcode.clear(app, trial)
      WechatPlatform.log!(app, "qrcode_refresh", actor: current_admin, request: request)
      if request.xhr?
        render partial: "admins/apps/qrcode_panel", locals: { app: app, trial: trial }
      else
        redirect_to admins_app_path(app, helpers.application_context_params), status: :see_other
      end
    end

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

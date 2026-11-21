module Admins
  class WechatQrcodesController < BaseController
    before_action :require_super_admin!
    before_action { @app = App.wechat_mini_programs.find(params[:app_id]) }
    rescue_from Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable, with: :failed

    def refresh
      Wechat::MiniProgramQrcodes.clear(@app)
      Wechat.log!(@app, "qrcode_refresh", actor: current_admin, request: request)
      if request.xhr?
        render partial: "admins/apps/qrcode_panel", locals: { app: @app }
      else
        redirect_to admins_app_path(@app, helpers.application_context_params), status: :see_other
      end
    end

    def show
      version = params.fetch(:version, "release")
      bytes = Wechat::MiniProgramQrcodes.fetch(@app, version)
      mime = bytes.start_with?("\x89PNG".b) ? "image/png" : "image/jpeg"
      send_data bytes, type: mime, disposition: "inline", filename: "#{@app.appid}-#{version}.#{mime == "image/png" ? "png" : "jpg"}"
      response.headers["Cache-Control"] = "private, no-store"
    end

    private

    def failed(error)
      render json: { error: error.message }, status: :unprocessable_content
    end
  end
end

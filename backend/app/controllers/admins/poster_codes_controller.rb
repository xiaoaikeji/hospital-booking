module Admins
  class PosterCodesController < BaseController
    before_action :require_super_admin!

    def create
      target = params.require(:target).permit(:target_kind, :app_id, :official_account_qrcode_id, :page_path, :page_query).to_h.symbolize_keys
      bytes = Wechat::PosterCode.fetch(**target)
      mime = bytes.start_with?("\x89PNG".b) ? "image/png" : "image/jpeg"
      render json: { image: "data:#{mime};base64,#{Base64.strict_encode64(bytes)}" }
    rescue Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      render json: { error: error.message }, status: :unprocessable_content
    end
  end
end

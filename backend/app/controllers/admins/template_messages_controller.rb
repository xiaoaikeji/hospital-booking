module Admins
  class TemplateMessagesController < BaseController
    before_action :require_super_admin!
    rescue_from Notifications::Error, WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable, with: :failed

    def index
      @accounts = App.wechat_official_accounts.order(:nickname, :id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      return unless @app
      @config = Notifications::AccountConfiguration.new(@app)
      @templates = Notifications::TemplateMessages.new(@app).templates
    end

    def update
      @app = App.wechat_official_accounts.find(params[:app_id])
      input = params.require(:template_binding).permit(:event, :template_id, :revision, mapping: {}).to_h
      Notifications::TemplateMessages.new(@app).bind!(event: input["event"], template_id: input["template_id"], mapping: input["mapping"], revision: input["revision"], actor: current_admin, request: request)
      render json: { revision: Notifications::AccountConfiguration.new(@app).revision }
    end

    private

    def failed(error)
      if action_name == "index"
        @error = error.message
        @templates = []
        render :index
      else
        render json: { error: error.message }, status: :unprocessable_content
      end
    end
  end
end

module Admins
  class TemplateMessagesController < BaseController
    before_action :require_super_admin!
    before_action :load_app, only: %i[update destroy]
    rescue_from Notifications::Error, WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable, with: :failed

    def index
      @accounts = App.wechat_official_accounts.order(:nickname, :id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      return unless @app
      @config = Notifications::AccountConfiguration.new(@app)
      @templates = Notifications::TemplateMessages.new(@app).templates
    end

    def update
      input = params.require(:template_binding).permit(:event, :template_id, :revision, mapping: {}).to_h
      Notifications::TemplateMessages.new(@app).bind!(event: input["event"], template_id: input["template_id"], mapping: input["mapping"], revision: input["revision"], actor: current_admin, request: request)
      render json: { revision: Notifications::AccountConfiguration.new(@app).revision }
    end

    def destroy
      input = params.require(:template_binding).permit(:event, :revision)
      Notifications::TemplateMessages.new(@app).unbind!(event: input[:event], revision: input[:revision], actor: current_admin, request: request)
      redirect_to admins_template_messages_path(app_id: @app.id), notice: "模板绑定已解除", status: :see_other
    end

    private

    def load_app = @app = App.wechat_official_accounts.find(params[:app_id])

    def failed(error)
      if action_name == "index"
        @error = error.message
        @templates = []
        render :index
      elsif action_name == "destroy"
        redirect_to admins_template_messages_path(app_id: @app.id), alert: error.message, status: :see_other
      else
        render json: { error: error.message }, status: :unprocessable_content
      end
    end
  end
end

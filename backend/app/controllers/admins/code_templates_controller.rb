module Admins
  class CodeTemplatesController < BaseController
    before_action :require_super_admin!
    before_action -> { @catalog = WechatPlatform::CodeTemplates.new }

    def index
      @counts = MiniProgramRelease.group(:template_id).count
      @configured = @catalog.platform.missing.empty?
      @errors = {}
      @lists = %i[drafts templates].index_with do |key|
        if @configured && params[:fresh] == "1"
          begin
            next @catalog.refresh(key)
          rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
            @errors[key] = error.message
          end
        end
        @catalog.snapshot(key)
      end
      render partial: "lists" if params[:fresh] == "1"
    end

    def create
      @catalog.change!("add", id: params[:draft_id], type: params[:template_type], actor: current_admin, request: request)
      redirect_to admins_code_templates_path, notice: "草稿已加入模板库", status: :see_other
    end

    def destroy
      @catalog.change!("delete", id: params[:id], actor: current_admin, request: request)
      redirect_to admins_code_templates_path, notice: "模板已删除", status: :see_other
    end

    rescue_from WechatPlatform::Error do |error|
      redirect_to admins_code_templates_path, alert: error.message, status: :see_other
    end
  end
end

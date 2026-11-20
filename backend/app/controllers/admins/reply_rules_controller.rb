module Admins
  class ReplyRulesController < BaseController
    before_action :require_super_admin!
    before_action -> { @app = App.wechat_official_accounts.find(params[:app_id]); @config = Notifications::AccountConfiguration.new(@app) }

    def edit
      @data = @config.data
    end

    def update
      input = params.require(:reply_rules).permit(:revision, :follow_first, :follow_again, keywords: [ :words, :match, :reply_id ]).to_h
      @config.save_rules!(input, actor: current_admin, request: request)
      redirect_to edit_admins_app_reply_rules_path(@app), notice: "自动回复规则已保存", status: :see_other
    rescue Notifications::Error => error
      @data = input
      flash.now[:alert] = error.message
      render :edit, status: :unprocessable_content
    end
  end
end

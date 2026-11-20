module Admins
  class OfficialAccountMenusController < BaseController
    before_action :require_super_admin!
    before_action :load_account, except: :index
    rescue_from WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable, with: :operation_failed

    def index
      @accounts = App.wechat_official_accounts.order(:nickname, :id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      return unless @app
      @menu = OfficialAccountMenu.find_by(app: @app) || OfficialAccountMenu.new(app: @app)
      @targets = App.wechat_mini_programs.order(:nickname, :id)
    end

    def publish
      buttons = params[:buttons]
      raise WechatPlatform::Error, "请提交完整的菜单列表" unless buttons.is_a?(Array)
      nodes = buttons.map { |node| node.respond_to?(:to_unsafe_h) ? node.to_unsafe_h : node }
      service.publish!(nodes, params[:revision].to_s, clear: params[:clear] == true)
      flash[:notice] = nodes.empty? ? "公众号菜单已清空" : "菜单已发布到微信"
      render json: { redirect: editor_path }
    end

    def pull
      result = service.pull!(params[:revision].to_s, accept: params[:accept] == "1")
      message = result == :mismatch ? "微信当前菜单与上次提交内容不同，请核对后选择保留的菜单" : "已读取微信当前菜单"
      redirect_to editor_path, notice: message, status: :see_other
    end

    def articles
      page = Integer(params[:page].to_s, exception: false) || 1
      render json: service.articles(page.clamp(1, 100000))
    end

    def image
      bytes, mime = service.image(params[:media_id].to_s)
      send_data bytes, type: mime, disposition: "inline"
    end

    def media
      render json: service.upload!(params[:file], params[:kind].to_s)
    end

    private

    def editor_path = admins_official_account_menus_path(app_id: @app.id)
    def load_account = @app = App.wechat_official_accounts.find(params[:app_id])
    def service = WechatPlatform::OfficialAccountMenus.new(@app, actor: current_admin, request: request)

    def operation_failed(error)
      if action_name == "pull"
        redirect_to editor_path, alert: error.message, status: :see_other
      else
        row = OfficialAccountMenu.find_by(app: @app) if action_name == "publish"
        render json: { error: error.message, pending: !row&.pending_buttons.nil?, revision: row&.revision }, status: :unprocessable_content
      end
    end
  end
end

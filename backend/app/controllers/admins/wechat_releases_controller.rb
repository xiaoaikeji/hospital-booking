module Admins
  class WechatReleasesController < BaseController
    before_action :require_super_admin!
    before_action :load_app
    before_action :load_release, only: %i[trial verify_upload submit close destroy]
    before_action :load_audit, only: %i[sync resolve withdraw publish]

    def new
      @templates = []
      platform = WechatPlatform::ComponentToken.new
      @templates = platform.with_token { |token| platform.client.templates(token) }
    rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      flash.now[:alert] = error.message
    end

    def create
      service.upload!(params.require(:release).permit(:template_id, :version, :description).to_h)
      back("体验版已上传")
    end

    def verify_upload
      raise ActionController::BadRequest unless params[:confirmed] == "1"
      service.verify_upload!(@release)
      back("微信体验版已核实")
    end

    def trial
      bytes = service.trial(@release)
      send_data bytes, type: bytes.start_with?("\x89PNG".b) ? "image/png" : "image/jpeg", disposition: "inline"
    end

    def submit
      service.submit!(@release, description: params[:description].to_s, auto_publish: params[:auto_publish] == "1",
        expected_round: params.require(:expected_round))
      back("微信已受理本轮审核")
    end

    def sync
      service.sync!(@audit)
      back("已核对本轮状态")
    end

    def resolve
      raise ActionController::BadRequest unless params[:confirmed] == "1"
      service.resolve!(@audit, outcome: params[:outcome], confirmed_id: params[:audit_id])
      back("核实结果已登记")
    end

    def withdraw
      service.withdraw!(@audit)
      back("审核已撤回")
    end

    def publish
      service.publish!(@audit)
      back("版本已发布")
    end

    def close
      service.retire!(@release, delete: false)
      back("本地版本记录已关闭")
    end

    def destroy
      service.retire!(@release, delete: true)
      back("本地版本记录已删除")
    end

    rescue_from WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable do |error|
      redirect_to admins_app_path(@app), alert: error.message, status: :see_other
    end

    private

    def load_app = @app = App.where(provider: "wechat").find(params[:app_id])
    def load_release = @release = @app.mini_program_releases.find(params[:id])
    def load_audit = @audit = @app.mini_program_audits.find(params[:id])
    def back(message) = redirect_to(admins_app_path(@app), notice: message, status: :see_other)
    def service = WechatPlatform::MiniProgramReleaseService.new(@app, actor: current_admin, request: request)
  end
end

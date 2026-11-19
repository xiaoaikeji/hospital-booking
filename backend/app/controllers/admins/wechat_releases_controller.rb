module Admins
  class WechatReleasesController < BaseController
    before_action :require_super_admin!
    before_action :load_app
    before_action :load_release, only: %i[trial verify_upload retry_upload submit close destroy]
    before_action :load_audit, only: %i[sync resolve withdraw publish resume_auto mode screenshot]

    def new
      unless WechatPlatform::ReleaseActions.new(@app).upload?
        return redirect_to admins_mini_program_releases_path(app_id: @app.id), alert: "请先完成平台授权或核实上次操作"
      end
      @templates = []
      @templates = WechatPlatform::CodeTemplates.new.refresh(:templates)
    rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      flash.now[:alert] = error.message
    end

    def create
      attributes = params.require(:release).permit(:template_id, :template_type, :version, :description)
      service.upload!(attributes, WechatPlatform::CodeTemplates.new)
      back("体验版已上传")
    end

    def retry_upload
      service.retry_upload!(@release)
      back("已使用原模板快照重新上传体验版")
    end

    def resume_auto
      service.resume_auto!(@audit)
      back("已将本轮重新加入自动发布队列")
    end

    def verify_upload
      raise ActionController::BadRequest unless params[:confirmed] == "1"
      service.verify_upload!(@release, not_uploaded: params[:outcome] == "not_uploaded")
      back("微信体验版已核实")
    end

    def trial
      bytes = service.trial(@release)
      send_data bytes, type: bytes.start_with?("\x89PNG".b) ? "image/png" : "image/jpeg", disposition: "inline"
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      render json: { error: error.message }, status: :service_unavailable
    end

    def submit
      service.submit!(@release, description: params[:description].to_s, auto_publish: params[:auto_publish] == "1",
        expected_round: params.require(:expected_round))
      back("微信已受理本轮审核")
    end

    def sync
      raise WechatPlatform::Error, "本轮已结束，请刷新查看结果" unless round_actions.sync?
      message = service.sync!(@audit)
      back(message.is_a?(String) ? message : "已核对本轮状态")
    end

    def resolve
      raise ActionController::BadRequest unless params[:confirmed] == "1"
      service.resolve!(@audit, outcome: params[:outcome], confirmed_id: params[:audit_id])
      back("核实结果已登记")
    end

    def screenshot
      no_store
      image = WechatPlatform::AuditScreenshot.fetch(@app, @audit, Integer(params[:index], 10))
      send_data image[:bytes], type: image[:type], disposition: "inline"
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      render plain: error.message, status: :service_unavailable
    end

    def mode
      values = [params.require(:expected_mode), params.require(:auto_publish)]
      raise ActionController::BadRequest unless (values - %w[0 1]).empty?
      service.change_mode!(@audit, auto_publish: values.last == "1", expected: values.first == "1")
      back("已保存本轮发布方式")
    end

    def withdraw
      service.withdraw!(@audit)
      back("审核已撤回")
    end

    def publish
      raise WechatPlatform::Error, "本轮当前不能人工发布，请刷新查看进度" unless round_actions.manual_publish?
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
      if request.format.json?
        uncertain = @app && (@app.mini_program_releases.exists?(status: "upload_unknown") ||
          @app.mini_program_audits.exists?(status: %w[submit_unknown withdraw_unknown]) || @app.mini_program_audits.exists?(publication: "publish_unknown"))
        flash[:alert] = "#{error.message}。请先核实上次操作。" if uncertain
        revision = error.round_id if error.is_a?(WechatPlatform::MiniProgramReleaseService::SubmissionRejected)
        render json: { error: error.message, reconcile: uncertain, expected_round: revision }, status: :unprocessable_content
      else
        redirect_to return_path, alert: error.message, status: :see_other
      end
    end

    private

    def load_app = @app = App.wechat_mini_programs.find(params[:app_id])
    def load_release = @release = @app.mini_program_releases.find(params[:id])
    def load_audit = @audit = @app.mini_program_audits.find(params[:id])
    def back(message)
      flash[:notice] = message
      request.format.json? ? render(json: { ok: true }) : redirect_to(return_path, status: :see_other)
    end

    def return_path
      if params[:detail].present?
        record = @app.mini_program_releases.find_by(id: params[:detail])
        list = params[:list].permit(:q, :app_id, :status, :in_progress, :page) if params[:list].is_a?(ActionController::Parameters)
        return admins_mini_program_release_path(record, list: list) if record
        return admins_mini_program_releases_path(list || { app_id: @app.id })
      end
      return admins_app_path(@app) unless params[:list].is_a?(ActionController::Parameters)
      admins_mini_program_releases_path(params[:list].permit(:app_id, :q, :status, :in_progress, :page))
    end
    def round_actions = WechatPlatform::ReleaseActions.new(@app, release: @audit.mini_program_release, round: @audit)
    def service = WechatPlatform::MiniProgramReleaseService.new(@app, actor: current_admin, request: request)
  end
end

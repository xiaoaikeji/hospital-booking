module Admins
  class MiniProgramReleasesController < BaseController
    before_action :require_super_admin!

    def index
      @filters = params.permit(:q, :app_id, :status, :in_progress).to_h.compact_blank
      @apps = App.wechat_mini_programs.includes(:app_authorization).order(:nickname, :appid)
      @upload_apps = @apps.select { |app| WechatPlatform::ReleaseActions.new(app).upload? }
      rows = MiniProgramRelease.with_progress.merge(App.wechat_mini_programs)
      rows = rows.where(app_id: @filters["app_id"]) if @filters["app_id"]
      rows = rows.where("progress = ?", @filters["status"]) if @filters["status"]
      rows = rows.where("progress IN (?)", MiniProgramRelease::IN_PROGRESS) if @filters["in_progress"] == "1"
      if @filters["q"]
        rows = rows.where("apps.nickname ILIKE :term OR apps.appid ILIKE :term OR mini_program_releases.version ILIKE :term",
          term: "%#{App.sanitize_sql_like(@filters['q'])}%")
      end
      read_quota if params[:quota] == "1" && params[:fragment] != "1"
      rows = rows.preload(:effective_audit, :latest_audit, app: :app_authorization).order(Arel.sql("activity_at DESC, mini_program_releases.id DESC"))
      @pagy, @releases = pagy(rows, count: rows.except(:select, :order).count)
      @pagy, @releases = pagy(rows, page: @pagy.last, count: @pagy.count) if @pagy.page > @pagy.last
      render partial: "list" if params[:fragment] == "1"
    end

    def show
      @release = MiniProgramRelease.with_progress.merge(App.wechat_mini_programs).find(params[:id])
      @rounds = @release.mini_program_audits.includes(:operator).order(id: :desc)
      @activity = Log.operations_visible_to(current_admin).where(target_type: "App", target_id: @release.app_id, category: "wechat", status: "success")
        .where("details ->> 'release_id' = :id OR details ->> 'round_id' IN (:rounds)", id: @release.id.to_s, rounds: @rounds.map { |r| r.id.to_s })
        .order(id: :desc)
      @operators = Admin.where(id: @activity.select(:actor_id)).index_by(&:id)
    end

    def confirmation
      @release = App.wechat_mini_programs.find(params.require(:app_id)).mini_program_releases.find(params[:id])
      @round = params[:round_id] ? @release.mini_program_audits.find(params[:round_id]) : @release.latest_audit
      actions = WechatPlatform::ReleaseActions.new(@release.app, release: @release, round: @round)
      if params[:operation] == "submit" && actions.submit?
        @revision = @release.app.mini_program_audits.maximum(:id).to_i
        @warnings = WechatPlatform::AuditPreflight.new(@release.app).messages
        render partial: "submit"
      elsif params[:operation] == "mode" && actions.change_mode?
        render partial: "mode"
      else
        render plain: "状态或授权已变化，请刷新页面。", status: :conflict
      end
    end

    def read_quota
      app = @apps.find(&:platform_authorized?)
      raise WechatPlatform::Error, "请先完成一个微信小程序的平台授权" unless app
      @quota = Wechat::MiniProgramCodeClient.new(WechatPlatform::AuthorizerToken.fetch(app)).quota
    rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      @quota_error = error.message
    end
    private :read_quota

    def templates
      catalog = WechatPlatform::CodeTemplates.new
      render json: { templates: catalog.refresh(:templates) }
    rescue WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected => error
      render json: { error: "#{error.message}。可手工填写模板资料。", templates: catalog.snapshot(:templates) || [] }
    end
  end
end

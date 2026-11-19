module Admins
  class AppsController < BaseController
    before_action :require_super_admin!
    before_action :load_app, only: %i[show edit update destroy]

    def index
      @filters = params.permit(:q, :provider, :status).to_h.compact_blank
      scope = App.where(@filters.slice("provider", "status"))
      if @filters["q"]
        scope = scope.where("nickname ILIKE :q OR appid ILIKE :q", q: "%#{App.sanitize_sql_like(@filters["q"])}%")
      end
      @pagy, @apps = pagy(scope.order(id: :desc))
    end

    def show
      return unless @app.provider == "wechat"
      @platform = WechatPlatform::ComponentToken.new
      @releases = @app.mini_program_releases.includes(:operator).order(id: :desc)
      @audits = @app.mini_program_audits.includes(:operator, :mini_program_release).order(id: :desc)
      @round_revision = @app.mini_program_audits.maximum(:id).to_i
      @latest_round = @app.mini_program_audits.accepted_or_uncertain.maximum(:id)
    end

    def edit
      AppConfiguration.new(@app).credential
    rescue AppConfiguration::Invalid => error
      render plain: error.message, status: :unprocessable_content
    end

    def new
      @app = App.new(provider: "wechat")
    end

    def create
      @app = App.new(input.slice(:provider, :appid))
      save_app("create")
    end

    def update
      save_app("update")
    end

    def destroy
      @app.with_lock do
        @app.destroy!
        audit("destroy")
      end
      redirect_to admins_apps_path, notice: "应用已删除", status: :see_other
    rescue ActiveRecord::ActiveRecordError => error
      message = if @app.app_authorization
        "已有微信授权记录，只能停用"
      elsif @app.mini_program_releases.exists? || @app.mini_program_audits.exists?
        "已有发布或审核记录，只能停用"
      elsif error.is_a?(ActiveRecord::InvalidForeignKey)
        "已有业务记录，只能停用"
      else
        "删除失败"
      end
      audit("destroy", status: "failed", details: { reason: message })
      redirect_to admins_app_path(@app), alert: message
    end

    private

    def load_app = @app = App.find(params[:id])
    def input = params.require(:app).permit(:provider, :appid, :nickname, :memo, :status, :appsecret, :clear_secret, :revision)

    def save_app(action)
      App.transaction(requires_new: true) do
        @app.lock! if @app.persisted?
        config = AppConfiguration.new(@app)
        if @app.persisted? && config.revision != input[:revision]
          raise AppConfiguration::Invalid, "配置已变更，请刷新页面后重新填写"
        end
        @app.assign_attributes(input.slice(:nickname, :memo, :status))
        config.assign(input)
        raise ActiveRecord::RecordInvalid, @app unless @app.valid?
        if @app.accessible? && (@app.status_changed? || config.credential_status != "已验证")
          config.verify!
        end
        fields = @app.changed - %w[verified_digest]
        @app.save!
        audit(action, details: { fields: fields })
        if fields.include?("appsecret")
          ActiveRecord.after_all_transactions_commit { Rails.cache.delete("apps/#{@app.id}/channel_token") }
        end
      end
      redirect_to admins_app_path(@app), notice: "应用已保存", status: :see_other
    rescue AppConfiguration::Invalid, HttpConnection::Unavailable, Wechat::BaseClient::Rejected, ActiveRecord::ActiveRecordError => error
      reason = case error
      when ActiveRecord::RecordInvalid then "请核对应用资料或重复的 AppID"
      when ActiveRecord::ActiveRecordError then "保存失败，请刷新页面"
      else error.message
      end
      audit(action, status: "failed", details: { reason: reason })
      @app.reload if @app.persisted?
      begin
        AppConfiguration.new(@app).credential
      rescue AppConfiguration::Invalid => failure
        return render plain: failure.message, status: :unprocessable_content
      end
      @app.errors.add(:base, reason)
      render(action == "create" ? :new : :edit, status: :unprocessable_content)
    end

    def audit(action, **options)
      Log.record!(category: "app", action: "app.#{action}", actor: current_admin, target: @app, request: request, **options)
    end
  end
end

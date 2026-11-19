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
    end

    def edit
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
      message = error.is_a?(ActiveRecord::InvalidForeignKey) || error.is_a?(ActiveRecord::RecordNotDestroyed) ? "已有授权、发布或业务记录，只能停用" : "删除失败"
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
      @app.errors.add(:base, reason)
      render(action == "create" ? :new : :edit, status: :unprocessable_content)
    end

    def audit(action, **options)
      Log.record!(category: "app", action: "app.#{action}", actor: current_admin, target: @app, request: request, **options)
    end
  end
end

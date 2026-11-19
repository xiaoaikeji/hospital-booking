module Admins
  class AppsController < BaseController
    before_action :require_super_admin!
    before_action :load_app, only: %i[show edit update destroy]

    def index
      @filters = params.permit(:q, :provider, :app_type, :status).to_h.compact_blank
      scope = App.where(@filters.slice("provider", "app_type", "status"))
      if @filters["q"]
        scope = scope.where("nickname ILIKE :q OR appid ILIKE :q", q: "%#{App.sanitize_sql_like(@filters["q"])}%")
      end
      @pagy, @apps = pagy(scope.preload(:app_authorization).order(id: :desc))
      @component_configured = WechatPlatform::ComponentToken.new.missing.empty? if @apps.any? { |app| app.provider == "wechat" }
    end

    WECHAT_TABS = {
      "overview" => "基本资料", "releases" => "代码发布", "experiencers" => "体验者",
      "privacy" => "隐私指引", "categories" => "服务类目", "domains" => "域名管理"
    }.freeze

    def show
      @tabs = @app.code_capable? ? WECHAT_TABS : WECHAT_TABS.slice("overview")
      @tab = @tabs.key?(params[:tab]) ? params[:tab] : "overview"
      return load_management_tab unless %w[overview releases].include?(@tab)
      return unless @app.provider == "wechat"
      @platform = WechatPlatform::ComponentToken.new
      return unless @app.code_capable?
      @trial = @app.mini_program_releases.find_by(current_build: true)
      @online_version = @app.mini_program_audits.where(publication: "published").order(id: :desc).pick(:version)
      history = @app.mini_program_audits.order(id: :desc)
      @current_round = history.accepted_or_uncertain.first || history.first
      if @tab == "releases"
        @audit_history, @audits = pagy(history, limit: 10)
        if params[:verify_version] == "1" && @app.platform_authorized?
          token = WechatPlatform::AuthorizerToken.fetch(@app)
          @version_info = Wechat::MiniProgramCodeClient.new(token).version_info
        end
      else
        @audits = history.limit(3)
      end
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      @version_error = error.message
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
      @app = App.new(input.slice(:provider, :app_type, :appid))
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
      redirect_to admins_apps_path(helpers.application_list_context), notice: "应用已删除", status: :see_other
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
      redirect_to admins_app_path(@app, helpers.application_context_params), alert: message
    end

    private

    def load_management_tab
      return unless @app.platform_authorized?

      case @tab
      when "experiencers" then @experiencers = WechatPlatform::Experiencers.new(@app).list
      when "privacy" then @privacy = WechatPlatform::PrivacySettings.new(@app).read
      when "categories" then @category_page = WechatPlatform::AppCategories.new(@app).page
      when "domains" then @domain_settings = WechatPlatform::AppDomains.new(@app).snapshot
      end
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      @tab_error = error.message
    end

    def load_app = @app = App.find(params[:id])
    def input = params.require(:app).permit(:provider, :app_type, :appid, :nickname, :memo, :status, :appsecret, :clear_secret, :revision)

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
      redirect_to admins_app_path(@app, helpers.application_context_params), notice: "应用已保存", status: :see_other
    rescue AppConfiguration::Invalid, WechatPlatform::Error, HttpConnection::Unavailable, Wechat::BaseClient::Rejected, ActiveRecord::ActiveRecordError => error
      reason = case error
      when ActiveRecord::RecordInvalid then "请核对标出的应用资料"
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

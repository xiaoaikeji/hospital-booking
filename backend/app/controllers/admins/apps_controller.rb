module Admins
  class AppsController < BaseController
    before_action :require_super_admin!
    before_action :load_app, only: %i[show edit update disable destroy]

    before_action :protect_credentials, only: %i[new edit create update]

    def index
      @filters = params.permit(:q, :provider, :app_type, :status).to_h.compact_blank
      provider = @filters["provider"].presence_in(App::PROVIDERS.keys) || "wechat"
      @types = provider == "wechat" ? App::TYPES : App::TYPES.slice("mini_program")
      type = @filters["app_type"].presence_in(@types.keys) || @types.keys.first
      @filters.merge!("provider" => provider, "app_type" => type)
      scope = App.where(@filters.slice("provider", "app_type", "status"))
      if @filters["q"]
        scope = scope.where("nickname ILIKE :q OR appid ILIKE :q", q: "%#{App.sanitize_sql_like(@filters["q"])}%")
      end
      @pagy, @apps = pagy(scope.order(id: :desc))
    end

    def show
      @tab = params[:tab] == "plugins" && @app.code_capable? ? "plugins" : "overview"
      @plugins = Wechat::AppPlugins.new(@app).list if @tab == "plugins"
    rescue Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      @tab_error = error.message
    end

    def edit
      load_form_credentials
      render :edit, status: :unprocessable_content if @credential_unavailable
    end

    def new
      context = helpers.application_list_context
      @app = App.new(provider: context["provider"] || "wechat", app_type: context["app_type"] || "mini_program")
      load_form_credentials
    end

    def create
      @app = App.new(input.slice(:provider, :app_type, :appid))
      save_app("create")
    end

    def update
      save_app("update")
    end

    def disable
      form = params[:app]
      unless form.is_a?(ActionController::Parameters) && form.keys == %w[revision]
        raise AppConfiguration::Invalid, "停用请求只能提交页面版本，请刷新后重试"
      end

      @app.with_lock(requires_new: true) do
        unless @app.accessible? && form[:revision] == AppConfiguration.new(@app).disable_revision
          raise AppConfiguration::Invalid, "应用状态或资料已变化，请刷新页面后重试"
        end

        @app.update!(status: "disabled")
        audit("update", details: { fields: %w[status] })
      end
      redirect_to admins_app_path(@app, helpers.application_context_params), notice: "应用已停用", status: :see_other
    rescue AppConfiguration::Invalid, ActiveRecord::ActiveRecordError => error
      reason = error.is_a?(AppConfiguration::Invalid) ? error.message : "停用失败，请刷新页面后重试"
      audit("update", status: "failed", details: { reason: reason })
      redirect_to edit_admins_app_path(@app, helpers.application_context_params), alert: reason, status: :see_other
    end

    def destroy
      @app.with_lock do
        @app.destroy!
        audit("destroy")
      end
      redirect_to admins_apps_path(helpers.application_list_context), notice: "应用已删除", status: :see_other
    rescue ActiveRecord::ActiveRecordError => error
      message = @app.errors[:base].first
      message ||= error.record.errors[:base].first if error.is_a?(ActiveRecord::RecordNotDestroyed) && error.record
      message ||= error.is_a?(ActiveRecord::InvalidForeignKey) ? "已有业务引用记录，只能停用" : "删除失败，请重试"
      audit("destroy", status: "failed", details: { reason: message })
      redirect_to admins_app_path(@app, helpers.application_context_params), alert: message
    end

    private

    def load_app = @app = App.find(params[:id])

    def input
      params.require(:app).permit(:provider, :app_type, :appid, :nickname, :memo, :status, :appsecret,
        :wechat_original_id, :callback_token, :callback_encoding_aes_key, :clear_secret, :clear_callback, :revision)
    end

    def protect_credentials
      response.headers["Cache-Control"] = "private, no-store"
    end

    def load_form_credentials
      config = AppConfiguration.new(@app)
      @credentials = config.editable_credentials
      @credential_revision = config.revision(@credentials) if @app.persisted?
      @credentials.each do |field, (_, source)|
        if source == AppConfiguration::DAMAGED_SOURCE
          @app.errors.add(field, "凭据密文已损坏。留空保留，或填写新值、清除系统配置。")
        end
      end
    rescue AppConfiguration::Invalid => error
      @credentials = { appsecret: [nil, "部署配置无效"] }
      @credential_unavailable = true
      @app.errors.add(:appsecret, error.message)
    end

    def save_app(action)
      App.transaction(requires_new: true) do
        @app.lock! if @app.persisted?
        config = AppConfiguration.new(@app)
        snapshot = config.editable_credentials
        if @app.persisted? && config.revision(snapshot) != input[:revision]
          raise AppConfiguration::Invalid, "配置已变更，请刷新页面后重新填写"
        end
        @app.assign_attributes(input.slice(:nickname, :memo, :status))
        if @app.wechat_official_account? && input.key?(:wechat_original_id)
          @app.wechat_original_id = input[:wechat_original_id].to_s.strip.presence
        end
        repaired = config.assign(input, snapshot: snapshot)
        raise ActiveRecord::RecordInvalid, @app unless @app.valid?
        verify_credential(config, damaged: snapshot.fetch(:appsecret).last == AppConfiguration::DAMAGED_SOURCE, repaired: repaired.include?(:appsecret))
        fields = @app.changed - %w[verified_digest]
        fields |= repaired.map(&:to_s)
        @app.save!
        audit(action, details: { fields: fields })
      end
      if input[:clear_secret] == "1" || input[:clear_callback] == "1"
        redirect_to edit_admins_app_path(@app, helpers.application_context_params), notice: "系统配置已清除", status: :see_other
      else
        redirect_to admins_app_path(@app, helpers.application_context_params), notice: "应用已保存", status: :see_other
      end
    rescue AppConfiguration::Invalid, HttpConnection::Unavailable, Wechat::BaseClient::Rejected,
      ActiveRecord::ActiveRecordError, ActiveRecord::Encryption::Errors::Base => error
      reason = case error
      when ActiveRecord::RecordInvalid then "请核对标出的应用资料"
      when ActiveRecord::ActiveRecordError then "保存失败，请刷新页面"
      when ActiveRecord::Encryption::Errors::Base then AppConfiguration::ENCRYPTION_UNAVAILABLE
      else error.message
      end
      audit(action, status: "failed", details: { reason: reason })
      @app.reload if @app.persisted?
      load_form_credentials
      @app.errors.add(:base, reason) unless @credential_unavailable
      render(action == "create" ? :new : :edit, status: :unprocessable_content)
    end

    def verify_credential(config, damaged:, repaired:)
      return unless @app.accessible?
      if damaged && !@app.status_changed?
        return unless repaired
        # An explicit clear may leave a previously unreadable credential unconfigured.
        return if input[:clear_secret] == "1" && config.credential.first.blank?
      end
      config.verify! if @app.status_changed? || config.credential_status != "已验证"
    end

    def audit(action, **options)
      Log.record!(category: "app", action: "app.#{action}", actor: current_admin, target: @app, request: request, **options)
    end
  end
end

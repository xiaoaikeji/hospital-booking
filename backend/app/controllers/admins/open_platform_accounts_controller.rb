module Admins
  class OpenPlatformAccountsController < BaseController
    before_action :require_super_admin!

    def index
      @query = params[:q].to_s.strip
      scope = OpenPlatformAccount.includes(:created_via_app).order(id: :desc)
      if @query.present?
        scope = scope.where("name ILIKE :term OR open_appid ILIKE :term", term: "%#{OpenPlatformAccount.sanitize_sql_like(@query)}%")
      end
      @pagy, @accounts = pagy(scope)
      @counts = App.where(open_platform_account_id: @accounts.map(&:id)).group(:open_platform_account_id).count
    end

    def show
      @account = OpenPlatformAccount.includes(:operator, :created_via_app).find(params[:id])
      @apps = @account.apps.preload(:app_authorization).order(:id)
      @pending = OpenPlatformOperation.where(open_platform_account: @account).includes(:app).index_by(&:app_id)
      @bindable = OpenPlatformAccount.bindable_apps
    end

    def new
      @bindable = OpenPlatformAccount.bindable_apps
    end

    def create
      @selected = App.wechat_accounts.find_by(id: params[:app_id])
      raise WechatPlatform::Error, "请选择已授权的微信应用" unless @selected
      service = WechatPlatform::OpenPlatformService.new(@selected, actor: current_admin, request: request)
      account = service.create!(name: params[:name].to_s.strip)
      redirect_to admins_open_platform_account_path(account), notice: "已登记开放平台账号并绑定 #{@selected.display_name}", status: :see_other
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      @bindable = OpenPlatformAccount.bindable_apps
      flash.now[:alert] = error.message
      render :new, status: :unprocessable_content
    end
  end
end

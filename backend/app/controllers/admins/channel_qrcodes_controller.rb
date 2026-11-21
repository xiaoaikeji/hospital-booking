module Admins
  class ChannelQrcodesController < BaseController
    before_action :require_super_admin!
    before_action :load_app, except: :index
    helper_method :list_path

    def index
      @accounts = App.wechat_official_accounts.order(:id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      return unless @app

      @query = params[:q].to_s.strip
      rows = OfficialAccountQrcode.where(app: @app)
      rows = rows.where("name ILIKE ?", "%#{OfficialAccountQrcode.sanitize_sql_like(@query)}%") if @query.present?
      @pagy, @codes = pagy(rows.order(id: :desc))
      @counts = OfficialAccountFan.for_app(@app).where(qr_scene: @codes.map(&:scene)).group(:qr_scene).count
    end

    def new
      return redirect_to list_path, alert: "请启用此公众号并配置 AppSecret" unless Wechat::AccessToken.configured?(@app)
      @code = OfficialAccountQrcode.new(app: @app)
      @key = service.form_key
      prepare_binding
    end

    def create
      @key = params[:form_key]
      @code = OfficialAccountQrcode.new(app: @app, name: params.dig(:official_account_qrcode, :name))
      prepare_binding
      revision = params.dig(:reply_binding, :revision) || @reply_config.revision
      validate = -> { @reply_config.validate_code_binding!(mode: @binding["mode"], reply_id: @binding["reply_id"], revision: revision) }
      service.create!(@code, @key, validate: validate) do |code|
        @reply_config.bind_code!(code, mode: @binding["mode"], reply_id: @binding["reply_id"], revision: revision, actor: current_admin, request: request)
      end
      redirect_to admins_channel_qrcodes_path(app_id: @app.id), notice: "渠道二维码已创建", status: :see_other
    rescue ActiveRecord::RecordInvalid
      render :new, status: :unprocessable_content
    rescue Notifications::Error, Wechat::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      flash.now[:alert] = error.message
      render :new, status: :unprocessable_content
    end

    def edit
      @code = OfficialAccountQrcode.where(app: @app).find(params[:id])
      prepare_binding
    end

    def update
      @code = OfficialAccountQrcode.where(app: @app).find(params[:id])
      prepare_binding
      @reply_config.bind_code!(@code, mode: @binding["mode"], reply_id: @binding["reply_id"], revision: params.dig(:reply_binding, :revision), actor: current_admin, request: request)
      redirect_to list_path, notice: "渠道码回复已保存", status: :see_other
    rescue Notifications::Error => error
      flash.now[:alert] = error.message
      render :edit, status: :unprocessable_content
    end

    def show
      code = OfficialAccountQrcode.where(app: @app).find(params[:id])
      send_data code.png, type: "image/png", disposition: "attachment", filename: "#{code.name}.png"
    end

    private

    def prepare_binding
      @reply_config = Notifications::AccountConfiguration.new(@app)
      @binding = params[:reply_binding]&.permit(:mode, :reply_id)&.to_h || (@code&.persisted? ? @reply_config.code_binding(@code.id) : { "mode" => "none" })
    end

    def load_app = @app = App.wechat_official_accounts.find(params[:app_id])
    def service = Wechat::ChannelQrcodes.new(@app, actor: current_admin, request: request)
    def list_path = admins_channel_qrcodes_path(params.permit(:q, :page).merge(app_id: @app.id))
  end
end

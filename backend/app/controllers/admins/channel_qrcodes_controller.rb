module Admins
  class ChannelQrcodesController < BaseController
    before_action :require_super_admin!
    before_action :load_app, except: :index
    helper_method :list_path

    def index
      @accounts = App.wechat_official_accounts.includes(:app_authorization).order(:id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      return unless @app

      @query = params[:q].to_s.strip
      rows = OfficialAccountQrcode.where(app: @app)
      rows = rows.where("name ILIKE ?", "%#{OfficialAccountQrcode.sanitize_sql_like(@query)}%") if @query.present?
      @pagy, @codes = pagy(rows.order(id: :desc))
      @counts = OfficialAccountFan.for_app(@app).where(qr_scene: @codes.map(&:scene)).group(:qr_scene).count
    end

    def new
      return redirect_to list_path, alert: "请先完成本公众号的平台授权" unless @app.platform_authorized?
      @code = OfficialAccountQrcode.new(app: @app)
      @key = service.form_key
    end

    def create
      @key = params[:form_key]
      @code = OfficialAccountQrcode.new(app: @app, name: params.dig(:official_account_qrcode, :name))
      service.create!(@code, @key)
      redirect_to admins_channel_qrcodes_path(app_id: @app.id), notice: "渠道二维码已创建", status: :see_other
    rescue ActiveRecord::RecordInvalid
      render :new, status: :unprocessable_content
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      flash.now[:alert] = error.message
      render :new, status: :unprocessable_content
    end

    def show
      code = OfficialAccountQrcode.where(app: @app).find(params[:id])
      send_data code.png, type: "image/png", disposition: "attachment", filename: "#{code.name}.png"
    end

    private

    def load_app = @app = App.wechat_official_accounts.find(params[:app_id])
    def service = WechatPlatform::ChannelQrcodes.new(@app, actor: current_admin, request: request)
    def list_path = admins_channel_qrcodes_path(params.permit(:q, :page).merge(app_id: @app.id))
  end
end

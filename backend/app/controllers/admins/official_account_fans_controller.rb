module Admins
  class OfficialAccountFansController < BaseController
    before_action :require_super_admin!

    def index
      @accounts = App.wechat_official_accounts.order(:id)
      @app = params[:app_id].present? ? @accounts.find(params[:app_id]) : @accounts.first
      return unless @app
      @query = params[:q].to_s.strip
      @status = params[:status].presence_in(%w[subscribed unsubscribed])
      rows = OfficialAccountFan.for_app(@app).joins(user_app: :user).preload(user_app: :user)
      rows = rows.where(subscribed: @status == "subscribed") if @status
      if @query.present?
        term = "%#{User.sanitize_sql_like(@query)}%"
        rows = rows.where("users.nickname ILIKE :term OR users.user_no LIKE :term", term: term)
      end
      @pagy, @fans = pagy(rows.order(id: :desc))
      @channels = channel_names(@fans.map(&:qr_scene))
      users = @fans.map { |fan| fan.user_app.user_id }
      @joined = UserApp.where(user_id: users, provider: "wechat", appid: App.wechat_mini_programs.select(:appid))
        .where("sign_in_count > 0").distinct.pluck(:user_id).to_set
      @sync = OfficialAccountFanSync.where(app: @app).order(id: :desc).first
    end

    def show
      @app = App.wechat_official_accounts.find(params[:app_id])
      @fan = OfficialAccountFan.for_app(@app).preload(user_app: :user).find(params[:id])
      @channels = channel_names([@fan.qr_scene])
    end

    def sync
      app = App.wechat_official_accounts.find(params[:app_id])
      path = admins_official_account_fans_path(params.permit(:q, :status, :page).merge(app_id: app.id))
      started = Wechat::OfficialAccountFans.new(app).request_sync!(current_admin, request: request)
      redirect_to path, notice: started ? "已开始同步，稍后刷新本页查看结果" : "该公众号正在同步", status: :see_other
    rescue Wechat::Error => error
      redirect_to path, alert: error.message, status: :see_other
    end

    private

    def channel_names(scenes)
      OfficialAccountQrcode.where(app: @app, scene: scenes.compact).pluck(:scene, :name).to_h
    end
  end
end

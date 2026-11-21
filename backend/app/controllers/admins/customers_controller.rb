module Admins
  class CustomersController < BaseController
    STATUSES = { "active" => "正常", "disabled" => "已停用" }.freeze

    def index
      @apps = App.select(:id, :provider, :app_type, :appid, :nickname).order(:id)
      app = @apps.find(params[:app_id]) if params[:app_id].present?
      @filters = { q: params[:q].to_s.strip.presence, status: params[:status].presence_in(STATUSES.keys), app_id: app&.id }.compact

      rows = User.select(:id, :user_no, :nickname, :mobile, :mobile_verified_at, :status, :last_login_at)
      rows = rows.where(id: UserApp.for_app(app).select(:user_id)) if app
      rows = rows.where(status: @filters[:status]) if @filters[:status]
      if @filters[:q]
        term = "%#{User.sanitize_sql_like(@filters[:q])}%"
        rows = rows.where("user_no LIKE :term OR nickname ILIKE :term OR (mobile_verified_at IS NOT NULL AND mobile LIKE :term)", term: term)
      end

      @pagy, @customers = pagy(rows.order(User.arel_table[:last_login_at].desc.nulls_last, id: :desc))
      @identities_by_user = identities.where(user_id: @customers.map(&:id)).group_by(&:user_id)
      @list_context = @filters.merge(page: (@pagy.page if @pagy.page > 1)).compact
    end

    def show
      @customer = User.find(params[:id])
      @identities = identities.where(user_id: @customer.id)
        .select(:id, :provider, :appid, :status, :first_entry, "apps.nickname AS app_name").order(:id)
      @identities = @identities.select(:openid, :unionid) if current_admin.super_admin?
      @list_context = params.permit(:q, :status, :app_id, :page)
    end

    private

    def identities
      UserApp.joins(:app).select(:user_id, :sign_in_count, :last_sign_in_at, "apps.app_type")
    end
  end
end

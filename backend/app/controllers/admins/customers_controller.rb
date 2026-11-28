module Admins
  class CustomersController < BaseController
    STATUSES = { "active" => "正常", "disabled" => "已停用" }.freeze

    def index
      @apps = App.select(:id, :provider, :app_type, :appid, :nickname).order(:id)
      app = @apps.find(params[:app_id]) if params[:app_id].present?
      @filters = { q: params[:q].to_s.strip.presence, status: params[:status].presence_in(STATUSES.keys), app_id: app&.id }.compact

      rows = User.select(:id, :platform, :nickname, :avatar_url, :mobile, :mobile_verified_at, :status, :last_login_at,
                         "users.login_profile -> 'region' AS first_region")
      rows = rows.where(id: UserApp.for_app(app).select(:user_id)) if app
      rows = rows.where(status: @filters[:status]) if @filters[:status]
      rows = rows.matching_identity(@filters[:q], verified_mobile: true) if @filters[:q]

      @pagy, @customers = pagy(rows.order(User.arel_table[:last_login_at].desc.nulls_last, id: :desc))
      @identities_by_user = identities.where(user_id: @customers.map(&:id)).group_by(&:user_id)
      @list_context = @filters.merge(page: (@pagy.page if @pagy.page > 1)).compact
    end

    def show
      @customer = User.find(params[:id])
      @patients = @customer.patients.order(:id).pluck(:name, :gender, :age)
      @identities = identities.where(user_id: @customer.id)
        .select(:id, :status, :last_sign_in_at)
      @identities = @identities.select(:openid, :unionid) if current_admin.super_admin?
      owner = Log.where(source: "user", actor_type: "User", actor_id: @customer.id)
      visits = owner.where(category: "mini_program", action: "mini_program.entry", target_type: "UserApp", target_id: @identities.map(&:id))
      patient_logs = owner.where(category: "booking", action: Admins::RecordHistoryHelper::PATIENT_EVENTS.keys, target_type: "Patient")
      removed_ids = patient_logs.where(action: "patient.remove", status: "success", target_id: 1..)
        .where.not(target_id: Patient.select(:id)).select(:target_id)
      patients = patient_logs.where(target_id: @customer.patients.select(:id))
        .or(patient_logs.where(target_id: removed_ids))
      @history_pagy, @history = pagy(visits.or(patients).order(created_at: :desc, id: :desc), page_key: "history_page")
      @list_context = params.permit(:q, :status, :app_id, :page)
    end

    private

    def identities
      UserApp.joins(:app).select(:user_id, :provider, :appid, :sign_in_count, :first_entry, "apps.app_type", "apps.nickname AS app_name").order(:id)
    end
  end
end

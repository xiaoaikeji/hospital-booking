module Admins
  class AdministratorsController < BaseController
    before_action :require_super_admin!

    def index
      scope = Admin.order(:id)
      @query = params[:q].to_s.strip
      if @query.present?
        scope = scope.where("username ILIKE :term OR name ILIKE :term", term: "%#{Admin.sanitize_sql_like(@query)}%")
      end
      @pagy, @administrators = pagy(scope)
    end

    def new
      @administrator = Admin.new
    end

    def create
      @administrator = Admin.new(administrator_params)
      saved = Admin.transaction do
        if @administrator.save
          Log.record!(action: "admin.create", category: "security", actor: current_admin, target: @administrator,
            details: { "fields" => %w[username name role enabled password] }, request: request)
          true
        end
      end
      if saved
        redirect_to admins_administrators_path, notice: "管理员已创建", status: :see_other
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @administrator = Admin.find(params[:id])
    end

    def update
      @administrator = Admin.find(params[:id])
      if Admin.update_managed(@administrator, administrator_params, actor: current_admin, request: request)
        redirect_to admins_administrators_path, notice: "管理员已更新", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def administrator_params
      values = params.require(:administrator).permit(:username, :name, :role, :enabled, :password, :password_confirmation).to_h
      values.except!("password", "password_confirmation") if values["password"].blank?
      values
    end
  end
end

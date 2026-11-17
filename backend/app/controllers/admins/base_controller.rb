module Admins
  class BaseController < ApplicationController
    include Pagy::Method

    layout "admins"
    before_action :authenticate_admin!
    before_action :verify_enabled_admin
    before_action -> { response.headers["Cache-Control"] = "no-store" }
    before_action :refresh_storage_configuration
    rescue_from IntegrationSettings::ConfigurationError do
      render file: Rails.public_path.join("503.html"), layout: false, status: :service_unavailable
    end

    private

    def verify_enabled_admin
      return if current_admin.enabled?
      sign_out(:admin)
      redirect_to new_admin_session_path, alert: "账号已停用", status: :see_other
    end

    def require_super_admin!
      render file: Rails.public_path.join("403.html"), layout: false, status: :forbidden unless current_admin.super_admin?
    end

    def refresh_storage_configuration
      StorageConfiguration.refresh!
    end
  end
end

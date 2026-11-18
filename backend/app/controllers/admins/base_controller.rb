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

    # Tabler 的范围框使用短划线分隔起止日，单独选择一天时只提交一个日期。
    def list_date_range(value)
      return Range.new(nil, nil) if value.blank?

      parts = value.to_s.split("–", 3).map(&:strip)
      raise ActionController::BadRequest, "日期范围无效" if parts.size > 2 || parts.all?(&:blank?)

      days = parts.map do |part|
        next if part.empty?
        raise ActionController::BadRequest, "日期格式无效" unless /\A\d{4}-\d{2}-\d{2}\z/.match?(part)

        Date.iso8601(part)
      end
      days.first..days.last
    rescue Date::Error
      raise ActionController::BadRequest, "日期格式无效"
    end

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

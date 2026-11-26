module Admins
  class SystemSettings::AppointmentController < BaseController
    before_action :require_super_admin!, :refresh_storage_configuration
    before_action { @settings = AppointmentSettings.new }

    def edit
    end

    def update
      input = params.expect(appointment: [ :revision, *AppointmentSettings::FIELDS ])
      if @settings.save(input, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_appointment_path, notice: "预约设置已保存", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

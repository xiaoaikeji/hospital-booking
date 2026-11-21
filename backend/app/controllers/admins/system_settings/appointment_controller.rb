module Admins
  class SystemSettings::AppointmentController < BaseController
    before_action :require_super_admin!, :refresh_storage_configuration
    before_action { @settings = MiniProgramLoginSettings.new("appointment") }

    def edit
    end

    def update
      input = params.expect(appointment: [ :revision, :require_mobile_auth ])
      if @settings.save(input[:require_mobile_auth], expected_revision: input[:revision], actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_appointment_path, notice: "预约设置已保存", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

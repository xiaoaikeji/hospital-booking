module Admins
  class SystemSettings::AppointmentController < BaseController
    NIGHT_SHIFT_FAILURE = "晚班设置未保存，请重试"

    before_action :require_super_admin!, :refresh_storage_configuration
    before_action only: %i[edit update] do
      @settings = MiniProgramLoginSettings.new("appointment")
      @night_enabled = Schedule.night_enabled?
    end

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

    def night_shift
      value = params.expect(Schedule::NIGHT_SETTING)
      raise ActionController::BadRequest unless %w[0 1].include?(value)

      setting = nil
      Setting.transaction(requires_new: true) do
        Setting.insert_all([ { key: "appointment" } ], unique_by: :key)
        setting = Setting.lock.find_by!(key: "appointment")
        enabled = value == "1"
        if setting.settings.fetch(Schedule::NIGHT_SETTING, false) != enabled
          setting.write_value(Schedule::NIGHT_SETTING, enabled)
          setting.save!
          audit_night_shift(setting, fields: [ Schedule::NIGHT_SETTING ])
        end
      end
      redirect_to edit_admins_system_settings_appointment_path, notice: "晚班设置已保存", status: :see_other
    rescue ActiveRecord::ActiveRecordError
      audit_night_shift(setting, status: "failed", reason: NIGHT_SHIFT_FAILURE)
      redirect_to edit_admins_system_settings_appointment_path, alert: NIGHT_SHIFT_FAILURE, status: :see_other
    end

    private

    def audit_night_shift(setting, status: "success", **details)
      Log.record!(category: "settings", action: "appointment.night_shift", actor: current_admin, target: setting,
        request: request, status: status, details: details)
    end
  end
end

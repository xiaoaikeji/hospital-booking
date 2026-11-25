module Admins
  class SystemSettings::HospitalController < BaseController
    skip_before_action :refresh_storage_configuration
    before_action :require_super_admin!
    before_action { @profile = HospitalProfile.new }

    def edit
    end

    def update
      input = params.expect(hospital: [ *HospitalProfile::FIELDS, :image, :remove_image ])
      if @profile.save(input, actor: current_admin, request: request)
        redirect_to edit_admins_system_settings_hospital_path, notice: "医院资料已保存", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    def image
      image = @profile.record&.hospital_image
      return head :not_found unless image&.attached?

      refresh_storage_configuration
      send_data image.download, type: image.content_type, disposition: "inline", filename: image.blob.key
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    end
  end
end

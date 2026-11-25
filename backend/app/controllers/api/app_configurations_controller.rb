module Api
  class AppConfigurationsController < ActionController::API
    before_action :load_app

    def show
      config = @app.slice(:provider, :appid, :nickname, :status)
      return render json: config, status: :forbidden unless @app.accessible?

      config[:links] = link_groups.transform_values do |group|
        group.effective.map do |link|
          link.slice(:id, :name, :link_type, :url, :params).merge(
            image_url: (api_app_configuration_image_url(@app.provider, @app.appid, link.id, link.image.blob.key) if link.image.attached?)
          )
        end
      end
      config[:directory] = directory
      profile = HospitalProfile.load_record
      config[:hospital] = profile ? profile.settings.slice(*HospitalProfile::FIELDS) : {}
      if profile&.hospital_image&.attached?
        config[:hospital][:image_url] = api_app_hospital_image_url(@app.provider, @app.appid, profile.hospital_image.blob.key)
      end
      render json: config
    end

    def image
      return head :forbidden unless @app.accessible?

      link = link_groups.values.flat_map(&:effective).find { |entry| entry.id.to_s == params[:id] }
      render_image(link&.image)
    end

    def hospital_image
      return head :forbidden unless @app.accessible?

      render_image(HospitalProfile.load_record&.hospital_image)
    end

    def directory_image
      return head :forbidden unless @app.accessible?

      entry = if params[:collection] == "departments"
        department = Department.find_by(id: params[:id])
        department if department&.visible_in_booking?
      else
        Doctor.current.enabled.with_attached_image.find_by(id: params[:id])
      end
      render_image(entry&.image)
    end

    private

    def directory
      department_ids = booking_departments.map { |department, _depth| department.id }.to_set
      {
        departments: booking_departments.map do |department, depth|
          image_url = directory_image_url("departments", department)
          { id: department.id.to_s, name: department.name, depth: depth,
            icon: (department.name.each_grapheme_cluster.first unless image_url), image_url: image_url }
        end,
        doctors: Doctor.current.enabled.ordered.includes(:doctor_departments).with_attached_image.map do |doctor|
          visible_ids = doctor.doctor_departments.filter_map do |link|
            link.department_id.to_s if department_ids.include?(link.department_id)
          end
          doctor.slice(:name, :main_title, :good_in, :introduction, :display_on_homepage).merge(
            id: doctor.id.to_s, fee: doctor.fee_in_yuan, department_ids: visible_ids, image_url: directory_image_url("doctors", doctor)
          )
        end
      }
    end

    def booking_departments = @booking_departments ||= Department.booking_rows

    def directory_image_url(collection, entry)
      api_app_directory_image_url(@app.provider, @app.appid, collection, entry.id, entry.image.blob.key) if entry.image.attached?
    end

    def render_image(image)
      raise ActiveRecord::RecordNotFound unless image&.attached? && image.blob.key == params[:key]

      StorageConfiguration.refresh!
      send_data image.download, type: image.content_type, disposition: "inline", filename: image.blob.key
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    rescue IntegrationSettings::ConfigurationError
      head :service_unavailable
    end

    def load_app
      response.headers["Cache-Control"] = "no-store"
      @app = App.where(app_type: "mini_program").find_by!(provider: params[:provider], appid: params[:appid])
    end

    def link_groups = PageLinkConfiguration.new(app: @app).groups
  end
end

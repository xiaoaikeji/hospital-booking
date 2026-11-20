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
      render json: config
    end

    def image
      return head :forbidden unless @app.accessible?

      link = link_groups.values.flat_map(&:effective).find { |entry| entry.id.to_s == params[:id] }
      unless link&.image&.attached? && link.image.blob.key == params[:key]
        raise ActiveRecord::RecordNotFound
      end

      StorageConfiguration.refresh!
      send_data link.image.download, type: link.image.content_type, disposition: "inline", filename: link.image.blob.key
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    rescue IntegrationSettings::ConfigurationError
      head :service_unavailable
    end

    private

    def load_app
      response.headers["Cache-Control"] = "no-store"
      @app = App.where(app_type: "mini_program").find_by!(provider: params[:provider], appid: params[:appid])
    end

    def link_groups = PageLinkConfiguration.new(app: @app).groups
  end
end

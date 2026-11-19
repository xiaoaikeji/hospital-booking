module Api
  class LocationPicturesController < ActionController::API
    def show
      application = LocationInterfaceApplication.find_signed!(params[:review_token], purpose: "location_picture_#{params[:id]}")
      unless application.app_id.to_s == params[:app_id] && application.app.platform_authorized? && !%w[rejected not_accepted].include?(application.state)
        return head :not_found
      end
      picture = application.pictures.attachments.find(params[:id])
      StorageConfiguration.refresh!
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      send_data picture.download, type: picture.content_type, disposition: "inline", filename: picture.blob.key
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound, ActiveStorage::FileNotFoundError
      head :not_found
    rescue IntegrationSettings::ConfigurationError
      head :service_unavailable
    end
  end
end

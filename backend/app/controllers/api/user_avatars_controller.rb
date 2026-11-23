module Api
  class UserAvatarsController < ActionController::API
    def show
      blob = ActiveStorage::Blob.find_signed(params[:signed_id], purpose: :user_avatar)
      return head :not_found unless blob&.attachments&.exists?(record_type: "User", name: "avatar")

      StorageConfiguration.refresh!
      send_data blob.download, type: blob.content_type, disposition: "inline", filename: blob.key
    rescue ActiveStorage::FileNotFoundError
      head :not_found
    rescue IntegrationSettings::ConfigurationError
      head :service_unavailable
    end
  end
end

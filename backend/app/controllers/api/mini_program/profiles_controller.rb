module Api
  module MiniProgram
    class ProfilesController < BaseController
      def show
        render_profile
      end

      def update
        changes = {}
        if params.key?(:nickname)
          name = params[:nickname]
          unless name.is_a?(String) && name.strip.present? && name.strip.length <= 100
            return render_error(:unprocessable_content, "invalid_nickname", "昵称须为 1 至 100 个字符")
          end
          changes[:nickname] = name.strip
        end

        if params.key?(:avatar)
          StorageConfiguration.refresh!
          MediaUpload.attach(params[:avatar], as: :user_avatar) do |blob|
            path = api_user_avatar_path(blob.signed_id(purpose: :user_avatar))
            with_current_user { @user.update!(changes.merge(avatar: blob, avatar_url: path)) }
          end
        elsif changes.any?
          with_current_user { @user.update!(changes) }
        else
          return render_error(:unprocessable_content, "profile_missing", "请选择头像或填写昵称")
        end
        render_profile
      rescue MediaUpload::Invalid => error
        render_error(:unprocessable_content, "invalid_avatar", error.message)
      rescue MediaUpload::Failed, IntegrationSettings::ConfigurationError
        render_error(:service_unavailable, "upload_unavailable", "头像暂时无法保存，请重试")
      end
    end
  end
end

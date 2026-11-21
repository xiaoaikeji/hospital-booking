module Api
  module MiniProgram
    class SessionsController < BaseController
      skip_before_action :require_session
      skip_before_action :check_app_access, only: :destroy

      def create
        code = wechat_code
        return unless code
        render json: MiniProgramLogin.new(@app).call(code, scene: params[:scene]), status: :created
      end

      def destroy
        session_credential.revoke!
        head :no_content
      end
    end
  end
end

module Api
  module MiniProgram
    class SessionsController < BaseController
      skip_before_action :require_session
      skip_before_action :check_app_access, only: :destroy

      def create
        render json: MiniProgramLogin.new(@app).call(params[:code], context: visit_context, ip: IpLocation.from_request(request)), status: :created
      end

      def destroy
        session_credential.revoke!
        head :no_content
      end
    end
  end
end

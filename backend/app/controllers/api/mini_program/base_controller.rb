module Api
  module MiniProgram
    class BaseController < ActionController::API
      before_action :load_app
      before_action :check_app_access
      before_action :require_session

      rescue_from MiniProgramLogin::Disabled, with: :app_disabled
      rescue_from MiniProgramLogin::AccountDisabled do
        render_error(:forbidden, "account_disabled", "账号已停用")
      end
      rescue_from MiniProgramLogin::IdentityConflict do
        render_error(:conflict, "identity_conflict", "微信身份关联冲突，请联系医院")
      end
      rescue_from Wechat::MiniProgramLoginClient::MissingCode do |error|
        render_error(:bad_request, "code_invalid", error.message)
      end
      rescue_from MiniProgramLogin::SharingChanged, Wechat::Error, HttpConnection::Unavailable do |error|
        render_error(:service_unavailable, "wechat_unavailable", error.message)
      end
      rescue_from Wechat::BaseClient::Rejected do |error|
        if error.invalid_code?
          render_error(:unprocessable_content, "code_invalid", "微信凭证已失效，请重试")
        else
          render_error(:bad_gateway, "wechat_rejected", error.message)
        end
      end

      private

      def load_app
        response.headers["Cache-Control"] = "no-store"
        @app = App.wechat_mini_programs.find_by!(appid: params[:appid])
      end

      def check_app_access
        app_disabled unless @app.accessible?
      end

      def app_disabled
        render json: @app.slice(:provider, :appid).merge(status: "disabled"), status: :forbidden
      end

      def session_credential
        token = request.authorization.to_s[/\ABearer ([^\s]+)\z/i, 1]
        MiniProgramSession.new(@app, token)
      end

      def require_session(lock: false)
        @identity = session_credential.identity(lock: lock)
        unless @identity
          render_error(:unauthorized, "session_expired", "请重新登录")
          return
        end
        @user = @identity.user
        @user.lock! if lock
        MiniProgramLogin.check_account!(@identity, @user)
      end

      def render_profile
        render json: @user.account_profile.merge(booking_phone_required: Appointments::PhoneVerification.required_for?(@user))
      end

      def visit_context
        params.permit(:launch_scene, :channel_scene, :scene, :entry_id, :device_model, :operating_system, :device_platform).to_h
      end

      def render_error(status, code, message)
        render json: { code: code, message: message }, status: status
      end
    end
  end
end

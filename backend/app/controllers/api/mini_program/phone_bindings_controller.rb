module Api
  module MiniProgram
    class PhoneBindingsController < BaseController
      def create
        mobile = Wechat::MiniProgramLoginClient.new.phone_number(@app, params[:code])

        # Logout, expiry or disablement during the exchange must take effect before writing.
        UserApp.transaction do
          @app.lock!("FOR SHARE")
          raise MiniProgramLogin::Disabled unless @app.accessible?
          require_session(lock: true)
          return if performed?
          @user.verify_mobile!(mobile)
        end
        render_profile
      end
    end
  end
end

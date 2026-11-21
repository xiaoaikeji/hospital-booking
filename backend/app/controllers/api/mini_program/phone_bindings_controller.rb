module Api
  module MiniProgram
    class PhoneBindingsController < BaseController
      def create
        code = wechat_code
        return unless code
        mobile = Wechat::AccessToken.with_token(@app) do |token|
          Wechat::MiniProgramLoginClient.new.phone_number(@app.appid, token, code)
        end

        # Logout, expiry or disablement during the exchange must take effect before writing.
        UserApp.transaction do
          @app.lock!("FOR SHARE")
          raise MiniProgramLogin::Disabled unless @app.accessible?
          require_session(lock: true)
          return if performed?
          @user.update!(mobile: mobile, mobile_verified_at: Time.current)
        end
        render_profile
      end
    end
  end
end

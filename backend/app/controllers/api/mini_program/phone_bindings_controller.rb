module Api
  module MiniProgram
    class PhoneBindingsController < BaseController
      def create
        mobile = Wechat::MiniProgramLoginClient.new.phone_number(@app, params[:code])

        with_current_user { @user.verify_mobile!(mobile) }
        render_profile
      end
    end
  end
end

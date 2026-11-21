module Api
  module MiniProgram
    class ProfilesController < BaseController
      def show
        render_profile
      end
    end
  end
end

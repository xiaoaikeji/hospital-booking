module Api
  module MiniProgram
    class EntryScenesController < BaseController
      def create
        head MiniProgramLogin.record_scene(@identity, params[:scene]) ? :no_content : :service_unavailable
      end
    end
  end
end

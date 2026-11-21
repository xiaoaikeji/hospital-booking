module Api
  module MiniProgram
    class EntryScenesController < BaseController
      def create
        MiniProgramLogin.record_scene(@identity, params[:scene])
        head :no_content
      end
    end
  end
end

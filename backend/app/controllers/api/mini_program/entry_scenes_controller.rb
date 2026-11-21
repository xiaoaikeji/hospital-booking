module Api
  module MiniProgram
    class EntryScenesController < BaseController
      def create
        head MiniProgramVisit.record(@identity, visit_context, ip: IpLocation.from_request(request)) ? :no_content : :service_unavailable
      end
    end
  end
end

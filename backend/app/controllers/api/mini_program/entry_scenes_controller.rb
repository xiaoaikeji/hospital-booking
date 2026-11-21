module Api
  module MiniProgram
    class EntryScenesController < BaseController
      def create
        if params.key?(:intended_user_no) && params[:intended_user_no] != @user.user_no
          return render_error(:conflict, "entry_account_changed", "登录账号已变更")
        end
        context = visit_context
        unless MiniProgramVisit.valid_entry?(context)
          return render_error(:unprocessable_content, "entry_invalid", "无效的进入来源")
        end
        head MiniProgramVisit.record(@identity, context, ip: IpLocation.from_request(request)) ? :no_content : :service_unavailable
      end
    end
  end
end

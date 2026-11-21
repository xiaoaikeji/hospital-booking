module Admins
  class UserSharingController < BaseController
    before_action :require_super_admin!, :refresh_storage_configuration
    before_action { @settings = MiniProgramLoginSettings.new("wechat") }

    def edit
    end

    def update
      input = params.expect(sharing: [ :revision, { memberships: {} } ])
      if @settings.save(input[:memberships]&.to_h, expected_revision: input[:revision], actor: current_admin, request: request)
        redirect_to edit_admins_user_sharing_path, notice: "小程序用户共享已保存", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

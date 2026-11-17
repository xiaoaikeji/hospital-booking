module Admins
  class AccountsController < BaseController
    def edit
      @administrator = current_admin
    end

    def update
      @administrator = current_admin
      values = params.require(:account).permit(:current_password, :password, :password_confirmation)
      if values[:password].blank?
        return redirect_to edit_admins_account_path, notice: "未填写新密码，原密码保持不变", status: :see_other
      end
      saved = Admin.transaction do
        if @administrator.update_with_password(values)
          Log.record!(action: "admin.password", category: "security", actor: @administrator, target: @administrator,
            details: { "fields" => [ "password" ] }, request: request)
          true
        end
      end
      if saved
        bypass_sign_in(@administrator)
        redirect_to edit_admins_account_path, notice: "密码已修改", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

module Admins
  class SessionsController < Devise::SessionsController
    layout "admin_auth"

    def create
      super do |admin|
        Log.record!(action: "admin.sign_in", category: "security", actor: admin, request: request)
      end
    end

    def destroy
      Log.record!(action: "admin.sign_out", category: "security", actor: current_admin, request: request) if current_admin
      super
    end

    protected

    def after_sign_in_path_for(_resource) = admins_root_path
    def after_sign_out_path_for(_resource) = new_admin_session_path
  end
end

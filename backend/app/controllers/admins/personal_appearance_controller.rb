module Admins
  class PersonalAppearanceController < BaseController
    def update
      input = params.require(:appearance)
      raise ActionController::BadRequest unless input.is_a?(ActionController::Parameters)
      save(input.to_unsafe_h)
    end

    def destroy
      save({}, reset: true)
    end

    private

    def save(changes, reset: false)
      settings = AppearanceSettings.new(admin: current_admin)
      if settings.save(changes, reset: reset, expected_revision: params[:revision], actor: current_admin, request: request)
        render json: { values: settings.values, overrides: settings.overrides, revision: settings.revision }
      else
        render json: { error: settings.errors.full_messages.to_sentence }, status: :unprocessable_content
      end
    end
  end
end

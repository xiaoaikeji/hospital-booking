module Api
  class AppConfigurationsController < ActionController::API
    def show
      response.headers["Cache-Control"] = "no-store"
      app = App.where(app_type: "mini_program").find_by!(provider: params[:provider], appid: params[:appid])
      render json: app.slice(:provider, :appid, :nickname, :status), status: app.accessible? ? :ok : :forbidden
    end
  end
end

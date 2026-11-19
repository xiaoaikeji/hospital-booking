module Admins
  class OfficialAccountLinksController < BaseController
    before_action :require_super_admin!

    def index
      @q = params[:q].to_s.strip
      rows = App.wechat_official_accounts.includes(:app_authorization).order(id: :desc)
      if @q.present?
        rows = rows.where("nickname ILIKE :term OR appid ILIKE :term", term: "%#{App.sanitize_sql_like(@q)}%")
      end
      @pagy, @apps = pagy(rows)
    end
  end
end

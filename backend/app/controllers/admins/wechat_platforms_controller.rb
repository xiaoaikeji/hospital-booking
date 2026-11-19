module Admins
  class WechatPlatformsController < BaseController
    before_action :require_super_admin!

    def show
      @platform = WechatPlatform::ComponentToken.new
      accounts = AppAuthorization.joins(:app).merge(App.wechat_accounts).group("apps.app_type")
      @authorized = accounts.where.not(refresh_token: nil).count
      @revoked = accounts.where(refresh_token: nil).where.not(revoked_at: nil).count
    end
  end
end

module Admins
  class AppExperiencersController < WechatAppManagementController
    def create
      perform_wechat_change("tester_bind", tab: "experiencers", notice: "体验者已绑定") do
        WechatPlatform::Experiencers.new(@app).bind(params[:wechatid])
      end
    end

    def destroy
      perform_wechat_change("tester_unbind", tab: "experiencers", notice: "体验者已解绑") do
        WechatPlatform::Experiencers.new(@app).unbind(params[:userstr])
      end
    end
  end
end

module Admins
  class AppLocationInterfaceApplicationsController < WechatAppManagementController
    def create
      input = params.expect(location_application: [:api_name, :content, pictures: []])
      name = input[:api_name].to_s.strip
      content = input[:content].to_s.strip
      id = service.apply!(name, content, Array(input[:pictures]).compact_blank) do |application, picture|
        api_wechat_location_picture_url(@app, picture, review_token: application.signed_id(purpose: "location_picture_#{picture.id}", expires_in: 30.days))
      end
      redirect_to tab_path, notice: "申请已提交，微信单号 #{id}", status: :see_other
    rescue WechatPlatform::LocationInterfaces::Unconfirmed => error
      redirect_to tab_path, alert: error.message, status: :see_other
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      flash[:location_draft] = { app_id: @app.id, api_name: name.first(100), content: content.first(300) }
      message = Array(input[:pictures]).compact_blank.any? ? "#{error.message}。补充图片请重新选择。" : error.message
      redirect_to tab_path(view: "apply"), alert: message, status: :see_other
    end

    def verify
      service.verify!(params[:id], params[:observed_review], params[:confirmed])
      redirect_to tab_path, notice: "已登记核实结果", status: :see_other
    rescue WechatPlatform::Error, Wechat::BaseClient::Rejected, HttpConnection::Unavailable => error
      redirect_to tab_path, alert: error.message, status: :see_other
    end

    private

    def service = WechatPlatform::LocationInterfaces.new(@app, actor: current_admin, request: request)
    def tab_path(**options) = admins_app_path(@app, helpers.application_context_params.merge(tab: "location", **options))
  end
end

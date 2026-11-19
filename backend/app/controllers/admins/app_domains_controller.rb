module Admins
  class AppDomainsController < WechatAppManagementController
    def update
      kind = request.path_parameters.fetch(:kind).to_s
      fields = WechatPlatform::AppDomains::FIELDS.fetch(kind)
      input = params.fetch(:domains, ActionController::Parameters.new).permit(*fields.keys)
      clear = Array(params[:clear]).select { |field| fields.key?(field) }
      audit = { fields: (input.keys + clear).uniq }
      perform_wechat_change("#{kind}_domains", tab: "domains", notice: "已核对并保存#{WechatPlatform::AppDomains::TITLES.fetch(kind)}",
        details: audit) do
        audit[:fields] = WechatPlatform::AppDomains.new(@app).replace!(kind, texts: input, clear: clear, expected: params[:revision].to_s)
      end
    end
  end
end

module Admins
  class AppDomainsController < WechatAppManagementController
    def update
      kind = request.path_parameters.fetch(:kind).to_s
      fields = WechatPlatform::AppDomains::FIELDS.fetch(kind)
      input = params.fetch(:domains, ActionController::Parameters.new).permit(*fields.keys)
      clear = Array(params[:clear]).select { |field| fields.key?(field) }
      audit = { fields: (input.keys + clear).uniq }
      domains = WechatPlatform::AppDomains.new(@app)
      on_failure = ->(error) { render_invalid_domain(error, domains, kind, input, clear) }
      perform_wechat_change("#{kind}_domains", tab: "domains", notice: "已核对并保存#{WechatPlatform::AppDomains::TITLES.fetch(kind)}",
        details: audit, on_failure: on_failure) do
        audit[:fields] = domains.replace!(kind, texts: input, clear: clear, expected: params[:revision].to_s)
      end
    end

    private

    def render_invalid_domain(error, domains, kind, input, clear)
      return false unless error.is_a?(WechatPlatform::AppDomains::InvalidField)

      @tabs = AppsController::WECHAT_TABS.except("links")
      @tab = "domains"
      @domain_settings = domains.snapshot
      @domain_draft = { kind: kind, texts: input.to_h, clear: clear, field: error.field, message: error.message }
      flash.now[:alert] = "域名未保存，请检查标出的字段。"
      render "admins/apps/show", status: :unprocessable_content
      true
    end
  end
end

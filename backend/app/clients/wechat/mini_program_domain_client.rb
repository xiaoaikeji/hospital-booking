module Wechat
  class MiniProgramDomainClient < BaseClient
    PATHS = { "server" => "/wxa/modify_domain", "business" => "/wxa/setwebviewdomain" }.freeze

    def initialize(token)
      super()
      @token = token
    end

    def read(kind)
      call(kind, { action: "get" })
    end

    def replace(kind, domains)
      data = call(kind, domains.merge("action" => "set"))
      if data["errcode"].to_s != "0" || data.any? { |key, value| (key.start_with?("invalid_") || key == "no_icp_domain") && value.present? }
        raise HttpConnection::Unavailable, "微信未确认全部域名，请先重新读取核实"
      end
    end

    private

    def call(kind, body)
      json(:post, PATHS.fetch(kind), query: { access_token: @token }, body: body)
    end
  end
end

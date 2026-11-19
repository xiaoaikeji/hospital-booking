module WechatPlatform
  class ComponentToken
    KEYS = %i[appid appsecret token encoding_aes_key].freeze
    attr_reader :config

    def initialize
      @config = KEYS.index_with { |key| IntegrationSettings.read(:wechat_component, key, env_key: "WECHAT_COMPONENT_#{key.upcase}") }
    end

    def client = @client ||= Wechat::ComponentClient.new
    def missing = KEYS.select { |key| @config[key].blank? }
    def ticket_key = "wechat/component/#{@config[:appid]}/ticket"
    # 平台明确拒绝令牌时淘汰这次用的值，写接口不在此自动重放。
    def with_token
      token = access_token
      yield token
    rescue Wechat::BaseClient::Rejected => error
      if error.invalid_token?
        key = "wechat/component/#{@config[:appid]}/token"
        App.transaction do
          App.connection.execute("SELECT pg_advisory_xact_lock(71020001)")
          Rails.cache.delete(key) if token && Rails.cache.read(key) == token
        end
      end
      raise
    end

    def access_token
      raise Error, "第三方平台缺少 #{missing.join('、')}" if missing.any?
      key = "wechat/component/#{@config[:appid]}/token"
      Rails.cache.read(key) || App.transaction do
        App.connection.execute("SELECT pg_advisory_xact_lock(71020001)")
        Rails.cache.read(key) || begin
          ticket = Rails.cache.read(ticket_key)
          raise Error, "等待微信推送平台票据，请核对回调 URL" if ticket.blank?
          token, ttl = client.component_token(config, ticket)
          Rails.cache.write(key, token, expires_in: [ ttl.to_i - 300, 1 ].max.seconds)
          token
        end
      end
    end
  end
end

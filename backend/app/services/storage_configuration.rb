require "uri"

module StorageConfiguration
  MUTEX = Mutex.new
  SERVICES = %w[local tencent_cos].freeze
  FIELDS = { "active_storage" => %w[service], "tencent_cos" => %w[secret_id secret_key region bucket endpoint] }.freeze

  def self.reset!
    MUTEX.synchronize { @fingerprint = nil }
  end

  def self.service_name
    value = IntegrationSettings.read(:active_storage, :service, env_key: "ACTIVE_STORAGE_SERVICE")
    value.nil? ? "local" : value
  end

  def self.default_cos_endpoint(region)
    region = region.strip if region.is_a?(String)
    "https://cos.#{region}.myqcloud.com" if valid_value?("region", region)
  end

  def self.valid_value?(field, value)
    return false unless value.is_a?(String)

    case field
    when "service" then SERVICES.include?(value)
    when "region" then value.match?(/\A[a-z][a-z0-9-]*\z/)
    when "bucket" then value.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    when "endpoint"
      uri = URI.parse(value)
      uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
        !bot_endpoint?(uri)
    end
  rescue URI::InvalidURIError
    false
  end

  # Match bot paths on their providers' hosts so custom COS gateways can keep ordinary paths.
  def self.bot_endpoint?(uri)
    host = URI::RFC2396_PARSER.unescape(uri.host.b).downcase.delete_suffix(".")
    path = URI::RFC2396_PARSER.unescape(uri.path.b)

    case host
    when "hooks.slack.com", "hooks.slack-gov.com", "webhook.office.com", /\.webhook\.office\.com\z/
      true
    when /\A(?:(?:canary|ptb|www)\.)?discord(?:app)?\.com\z/
      %r{\A/api/(?:v[0-9]+/)?webhooks(?:/|\z)}i.match?(path)
    when "open.feishu.cn", "open.larksuite.com"
      %r{\A/open-apis/bot/(?:v[0-9]+/)?hook(?:/|\z)}i.match?(path)
    when "outlook.office.com"
      %r{\A/webhook(?:b2)?(?:/|\z)}i.match?(path)
    when "api.telegram.org"
      %r{\A/(?:file/)?bot}i.match?(path)
    else
      false
    end
  end
  private_class_method :bot_endpoint?

  def self.validate!(values)
    IntegrationSettings.with_snapshot(values) do
      selected = service_name
      unless SERVICES.include?(selected)
        raise IntegrationSettings::ConfigurationError, "存储方式无效"
      end
      if selected == "tencent_cos"
        require "active_storage/service/tencent_cos_service"
        ActiveStorage::Service::TencentCosService.settings
      end
      selected
    end
  end

  def self.fingerprint(raw)
    external = FIELDS.flat_map do |section, fields|
      fields.map do |field|
        env_key = section == "active_storage" ? "ACTIVE_STORAGE_SERVICE" : "TENCENT_COS_#{field.upcase}"
        [ ENV[env_key], Rails.application.credentials.dig(section.to_sym, field.to_sym) ]
      end
    end
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate([ raw.reject { |_key, value| value.empty? }, external ]))
  end

  def self.refresh!
    MUTEX.synchronize do
      raw = Setting.raw_snapshot
      version = fingerprint(raw)
      return if @fingerprint == version
      values = Setting.decode_snapshot(raw)
      selected = validate!(values)
      IntegrationSettings.with_snapshot(values) do
        # 先触发引擎的服务注册，再构建新实例；测试始终使用隔离 Disk。
        ActiveStorage::Blob.services
        selected = "test" if Rails.env.test?
        registry = ActiveStorage::Service::Registry.new(Rails.application.config.active_storage.service_configurations)
        service = registry.fetch(selected)
        registry.fetch("tencent_cos") if ActiveStorage::Blob.where(service_name: "tencent_cos").exists?
        ActiveStorage::Blob.services = registry
        ActiveStorage::Blob.service = service
        @fingerprint = version
      end
    end
  end

  class JobMiddleware
    def call(_worker, _job, _queue)
      StorageConfiguration.refresh!
      yield
    end
  end
end

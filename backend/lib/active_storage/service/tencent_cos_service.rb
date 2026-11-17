require "active_storage/service/s3_service"
require "uri"

module ActiveStorage
  # 沿用 Rails S3Service 的上传、下载、删除和签名 URL；仅适配 COS 配置与校验和兼容性。
  class Service::TencentCosService < Service::S3Service
    REQUIRED = %i[secret_id secret_key region bucket].freeze

    def self.settings(env: ENV, credentials: Rails.application.credentials)
      values = (REQUIRED + [ :endpoint ]).to_h do |key|
        [ key, IntegrationSettings.read(:tencent_cos, key, env_key: "TENCENT_COS_#{key.upcase}", env: env, credentials: credentials) ]
      end
      missing = REQUIRED.select { |key| values[key].nil? }
      if missing.any?
        raise IntegrationSettings::ConfigurationError, "腾讯云 COS 未配置：#{missing.join('、')}"
      end

      invalid = values.select { |_key, value| !value.nil? && !value.is_a?(String) }.keys
      raise IntegrationSettings::ConfigurationError, "腾讯云 COS 配置无效：#{invalid.join('、')}" if invalid.any?

      values.transform_values! { |value| value&.strip }
      unless values[:region].match?(/\A[a-z][a-z0-9-]*\z/) && values[:bucket].match?(/\A[a-z0-9][a-z0-9-]*\z/)
        raise IntegrationSettings::ConfigurationError, "腾讯云 COS region 或 bucket 配置无效"
      end
      values[:endpoint] ||= "https://cos.#{values[:region]}.myqcloud.com"
      endpoint = URI.parse(values[:endpoint])
      unless endpoint.is_a?(URI::HTTPS) && endpoint.host.present? && endpoint.userinfo.nil? && endpoint.query.nil? && endpoint.fragment.nil?
        raise IntegrationSettings::ConfigurationError, "腾讯云 COS endpoint 配置无效，须为 HTTPS API 地址"
      end
      values
    rescue URI::InvalidURIError
      raise IntegrationSettings::ConfigurationError, "腾讯云 COS endpoint 配置无效"
    end

    def initialize(env: ENV, credentials: Rails.application.credentials, **options)
      values = self.class.settings(env: env, credentials: credentials)
      super(
        bucket: values[:bucket], region: values[:region], endpoint: values[:endpoint],
        access_key_id: values[:secret_id], secret_access_key: values[:secret_key], force_path_style: false,
        request_checksum_calculation: "when_required", response_checksum_validation: "when_required",
        **options
      )
    end

    # 不通过对象 inspect 暴露 SDK 凭据。
    def inspect = "#<#{self.class.name} name=#{name.inspect}>"
    alias_method :to_s, :inspect
  end
end

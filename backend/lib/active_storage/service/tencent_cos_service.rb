require "active_storage/service/s3_service"

module ActiveStorage
  # 沿用 Rails S3Service 的上传、下载、删除和签名 URL；仅适配 COS 配置与校验和兼容性。
  class Service::TencentCosService < Service::S3Service
    class RequestFailed < ActiveStorage::Error; end

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
      unless %i[region bucket].all? { |field| StorageConfiguration.valid_value?(field.to_s, values[field]) }
        raise IntegrationSettings::ConfigurationError, "腾讯云 COS region 或 bucket 配置无效"
      end
      values[:endpoint] ||= StorageConfiguration.default_cos_endpoint(values[:region])
      unless StorageConfiguration.valid_value?("endpoint", values[:endpoint])
        raise IntegrationSettings::ConfigurationError, "腾讯云 COS endpoint 配置无效，须为 HTTPS API 地址"
      end
      values
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

    private

    def instrument(operation, payload = {})
      super do |event|
        yield event
      rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError => error
        raise error.class, cause: nil
      rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError
        # SDK errors can contain the endpoint or credentials echoed by a gateway.
        raise RequestFailed, "腾讯云 COS 请求失败，请稍后重试", cause: nil
      end
    end
  end
end

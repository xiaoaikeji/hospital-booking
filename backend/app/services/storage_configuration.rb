require "digest"

module StorageConfiguration
  MUTEX = Mutex.new
  FIELDS = { "active_storage" => %w[service], "tencent_cos" => %w[secret_id secret_key region bucket endpoint] }.freeze

  def self.reset!
    MUTEX.synchronize { @fingerprint = nil }
  end

  def self.validate!(values)
    IntegrationSettings.with_snapshot(values) do
      selected = IntegrationSettings.read(:active_storage, :service, env_key: "ACTIVE_STORAGE_SERVICE") || "local"
      unless %w[local tencent_cos].include?(selected)
        raise IntegrationSettings::ConfigurationError, "存储方式无效"
      end
      if selected == "tencent_cos"
        require "active_storage/service/tencent_cos_service"
        ActiveStorage::Service::TencentCosService.settings
      end
      selected
    end
  end

  def self.refresh!
    MUTEX.synchronize do
      raw = Setting.raw_snapshot
      external = FIELDS.flat_map do |section, fields|
        fields.map do |field|
          env_key = section == "active_storage" ? "ACTIVE_STORAGE_SERVICE" : "TENCENT_COS_#{field.upcase}"
          [ ENV[env_key], Rails.application.credentials.dig(section, field) ]
        end
      end
      fingerprint = Digest::SHA256.hexdigest(JSON.generate([ raw, external ]))
      return if @fingerprint == fingerprint
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
        @fingerprint = fingerprint
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

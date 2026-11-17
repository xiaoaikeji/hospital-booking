redis_url = ENV["REDIS_SIDEKIQ_URL"].presence || Rails.application.credentials.dig(:redis, :sidekiq_url).presence
if redis_url.nil? && Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  raise "REDIS_SIDEKIQ_URL 未配置（或 credentials redis.sidekiq_url）"
end
if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  cache_url = Rails.application.config.cache_store.last[:url]
  raise "任务与缓存不能使用相同 Redis 地址，请分配独立实例或不同 DB" if redis_url == cache_url
end
redis_url ||= "redis://localhost:6379/0" unless Rails.env.production?
redis_options = redis_url ? { url: redis_url } : {}

Sidekiq.configure_client { |config| config.redis = redis_options }
Sidekiq.configure_server do |config|
  config.redis = redis_options
  config.on(:startup) do
    config.server_middleware { |chain| chain.add StorageConfiguration::JobMiddleware }
    pool = ActiveRecord::Base.connection_db_config.max_connections
    if config.total_concurrency > pool
      raise "Sidekiq 并发 #{config.total_concurrency} 超过数据库连接池 #{pool}，请调低 SIDEKIQ_CONCURRENCY 或调大 DB_POOL"
    end
  end
end

# Worker 参数只传记录 ID；异常日志过滤敏感键，丢弃未经处理的原始 job JSON。
Sidekiq.default_configuration.error_handlers.replace([
  lambda do |error, context, config|
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    context = context.except(:jobstr)
    context[:job] = filter.filter(context[:job]) if context[:job].is_a?(Hash)
    Sidekiq::Config::ERROR_HANDLER.call(error, context, config)
  end
])

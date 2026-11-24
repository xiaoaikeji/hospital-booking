require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # 静态资源清单写入各 release 自己的 config/ 目录，避免新版 precompile 在切流前覆盖旧版清单。
  config.assets.manifest_path = Rails.root.join("config", "assets-manifest.json")

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for health check endpoints.
  health_check_path = ->(request) { request.path == "/up" || request.path == "/up/deploy" }
  config.ssl_options = { redirect: { exclude: health_check_path } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # 预编译不连接 Redis；运行时必须提供独立缓存地址，避免误用其他项目的 Redis。
  config.cache_store = if ENV["SECRET_KEY_BASE_DUMMY"].present?
    :null_store
  else
    redis_url = ENV["REDIS_CACHE_URL"].presence || Rails.application.credentials.dig(:redis, :cache_url).presence
    raise "REDIS_CACHE_URL 未配置（或 credentials redis.cache_url）" unless redis_url

    [ :redis_cache_store, { url: redis_url, expires_in: 1.day } ]
  end

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates, and optionally guard Host headers via APP_HOST.
  app_host = ENV["APP_HOST"].to_s.strip.sub(%r{\Ahttps?://}, "").sub(%r{/.*\z}, "").presence
  if app_host
    config.hosts << app_host
    config.host_authorization = { exclude: health_check_path }
    config.action_mailer.default_url_options = { host: app_host, protocol: "https" }
  else
    config.action_mailer.default_url_options = { host: "example.com", protocol: "https" }
  end

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end

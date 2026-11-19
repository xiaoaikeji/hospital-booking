require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module BookingWeb
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # 存储适配器由 Active Storage 按 storage.yml 加载。
    config.autoload_lib(ignore: %w[assets tasks active_storage])

    config.i18n.default_locale = :"zh-CN"
    config.i18n.available_locales = [ :"zh-CN", :en ]
    config.i18n.fallbacks = [ :en ]
    config.filter_redirect = [ "mp.weixin.qq.com/cgi-bin/componentloginpage" ]
    config.time_zone = "Asia/Shanghai"
    config.active_record.default_timezone = :utc
    ActiveSupport.on_load(:active_record_postgresqladapter) { self.datetime_type = :timestamptz }
    %w[primary_key deterministic_key key_derivation_salt].each do |key|
      value = ENV["ACTIVE_RECORD_ENCRYPTION_#{key.upcase}"].presence
      config.active_record.encryption.public_send("#{key}=", value) if value
    end

    # 校验状态由表单显式添加 is-invalid / invalid-feedback，避免额外包装破坏 Tabler 结构。
    config.action_view.field_error_proc = ->(html_tag, _instance) { html_tag }
    config.active_storage.variant_processor = :mini_magick
    # 文件归属与业务上传接口尚未接入，先关闭默认公开文件路由；服务层处理不受影响。
    config.active_storage.draw_routes = false
    config.active_job.queue_adapter = :sidekiq

    # Reader 在 initializer 中挂载，只有实际读取时才查表。
    config.x.integration_settings_reader = nil

    # Keep third-party logical paths namespaced: tabler/css/..., tabler/js/....
    config.assets.excluded_paths += Dir[Rails.root.join("vendor/assets/*")].select { |path| File.directory?(path) }
    config.assets.paths << Rails.root.join("vendor/assets").to_s

    # Publish compiled CSS only; SCSS remains build input.
    config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets").to_s

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end

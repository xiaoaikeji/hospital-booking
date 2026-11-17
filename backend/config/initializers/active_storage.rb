Rails.application.config.x.integration_settings_reader = ->(section, field) { Setting.read_integration_value(section, field) }

# 启动不查询设置表；请求和任务开始时按配置版本刷新服务对象。
Rails.application.config.to_prepare { StorageConfiguration.reset! }

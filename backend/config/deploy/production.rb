# frozen_string_literal: true

require_relative "../../lib/capistrano/local_config"

begin
  local_config = BookingCapistrano::LocalConfig.load!(
    stage: fetch(:stage),
    backend_root: File.expand_path("../..", __dir__)
  )
rescue BookingCapistrano::LocalConfig::Error => e
  abort e.message
end

# 直接使用 SSH 目标字符串（支持 ~/.ssh/config 别名或 user@host），
# 不在此覆盖 user/port/keys，账号、端口与私钥位置沿用本机 ~/.ssh/config。
server local_config.ssh_target, roles: %w[web app db]

set :deploy_to, local_config.deploy_to
set :repo_url, local_config.repo_url
set :branch, local_config.branch
set :booking_web_service, local_config.web_service
set :booking_jobs_service, local_config.jobs_service
set :booking_cap_wrapper, local_config.cap_wrapper
set :booking_health_check_url, local_config.health_check_url
set :booking_systemd_use_sudo, local_config.systemd_use_sudo

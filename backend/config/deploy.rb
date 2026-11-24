# config valid for current version and patch releases of Capistrano
lock "~> 3.20.0"

set :application, "booking"

# Rails 工程位于仓库根目录下的 backend/ 子目录，发布时只提取该目录内容到 release_path。
set :repo_tree, "backend"

# 仓库默认分支是 main；可在 deployer 本机配置中按需覆盖。
set :branch, "main"

# 服务器 Ruby 由 rbenv 提供，版本读取 backend/.ruby-version（去掉 RVM 风格的 "ruby-" 前缀）。
set :rbenv_type, :user
set :rbenv_ruby, File.read(File.expand_path("../.ruby-version", __dir__)).strip.delete_prefix("ruby-")

# 项目使用 Bundler 4.x；capistrano-bundler 默认按 2 处理。
set :bundle_version, 4

# 首次冷装或小内存主机并发编译原生 gem 易压垮资源，固定串行安装。
set :bundle_jobs, 1

# shared/public/assets 由所有 release 共用；保留与 keep_releases 一致的旧摘要供回滚使用。
set :keep_assets, 5

# 服务与健康检查默认值；可在 config/deploy/<stage>.local.yml 或 DEPLOY_* 环境变量覆盖。
set :booking_web_service, "booking.web.service"
set :booking_jobs_service, "booking.jobs.service"
set :booking_cap_wrapper, "/usr/local/bin/booking-cap"
set :booking_health_check_url, "http://127.0.0.1:3000/up"
set :booking_systemd_use_sudo, false

# 不设 linked_files：生产数据库、Redis 与 Rails 密钥统一由服务器环境文件提供。
# 跨 release 持久化的目录（capistrano-rails 会另外追加 public/assets）：
# storage 供 Active Storage :local 存储使用，再次发布后历史附件仍可读取。
append :linked_dirs,
       "log",
       "tmp/pids",
       "tmp/cache",
       "tmp/sockets",
       "storage",
       ".bundle"

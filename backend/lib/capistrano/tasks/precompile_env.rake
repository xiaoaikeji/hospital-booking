# assets:precompile 会在服务器上启动 Rails production 环境。
# 部署 SSH 会话不加载服务器环境文件中的真实密钥，使用 Rails 官方的
# SECRET_KEY_BASE_DUMMY=1 仅在资产预编译期间跳过密钥校验（含 dartsass:build）。
unless Rake::Task.task_defined?("deploy:assets:precompile")
  raise 'deploy:assets:precompile is not defined; require "capistrano/rails/assets" in the Capfile before importing lib/capistrano/tasks'
end

Rake::Task["deploy:assets:precompile"].clear_actions

namespace :deploy do
  namespace :assets do
    task :precompile do
      on release_roles(fetch(:assets_roles)) do
        within release_path do
          with rails_env: fetch(:rails_env),
               rails_groups: fetch(:rails_assets_groups),
               secret_key_base_dummy: "1" do
            execute :rake, "assets:precompile"
          end
        end
      end
    end
  end
end

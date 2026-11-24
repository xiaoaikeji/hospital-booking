# Propshaft 的 assets:clean[N] 依赖 :environment，会加载 production 环境；
# 与 precompile_env.rake 相同，仅对该远程命令临时传入 SECRET_KEY_BASE_DUMMY=1 与占位 DATABASE_URL。
# 正常部署时延后到 deploy:published（切流及健康检查成功）之后再清理，避免发布失败影响旧版本正在使用的资产。
unless Rake::Task.task_defined?("deploy:cleanup_assets")
  raise 'deploy:cleanup_assets is not defined; require "capistrano/rails/assets" in the Capfile before importing lib/capistrano/tasks'
end

Rake::Task["deploy:cleanup_assets"].clear_actions

namespace :deploy do
  task :cleanup_assets do
    next if deploying?

    Rake::Task["booking:run_cleanup_assets"].invoke
  end
end

namespace :booking do
  desc "Clean up old assets after deployment succeeds and current is published"
  task :cleanup_assets do
    next unless deploying?

    Rake::Task["booking:run_cleanup_assets"].invoke
  end

  task :run_cleanup_assets do
    next unless fetch(:keep_assets)

    on release_roles(fetch(:assets_roles)) do
      within release_path do
        with rails_env: fetch(:rails_env),
             secret_key_base_dummy: "1",
             database_url: fetch(:booking_assets_database_url) do
          execute :rake, "'assets:clean[#{fetch(:keep_assets)}]'"
        end
      end
    end
  end
end

after "deploy:published", "booking:cleanup_assets"

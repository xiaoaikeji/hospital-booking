# Propshaft 的 assets:clean[N] 依赖 :environment，会加载 production 环境；
# 与 precompile_env.rake 相同，仅对该远程命令临时传入 SECRET_KEY_BASE_DUMMY=1。
unless Rake::Task.task_defined?("deploy:cleanup_assets")
  raise 'deploy:cleanup_assets is not defined; require "capistrano/rails/assets" in the Capfile before importing lib/capistrano/tasks'
end

Rake::Task["deploy:cleanup_assets"].clear_actions

namespace :deploy do
  task :cleanup_assets do
    next unless fetch(:keep_assets)

    on release_roles(fetch(:assets_roles)) do
      within release_path do
        with rails_env: fetch(:rails_env), secret_key_base_dummy: "1" do
          execute :rake, "'assets:clean[#{fetch(:keep_assets)}]'"
        end
      end
    end
  end
end

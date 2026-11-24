# 在新 release 内准备数据库（在 assets:precompile 之后、deploy:publishing 之前）。
# 部署 SSH 会话不直接携带数据库与 Rails 密钥，统一经服务器侧 wrapper
# （默认 /usr/local/bin/booking-cap）读取环境文件并执行 bin/rails db:prepare。
namespace :booking do
  desc "Run bin/rails db:prepare in the new release via booking_cap_wrapper " \
       "(runs after assets:precompile, before deploy:publishing)"
  task :db_prepare do
    wrapper = fetch(:booking_cap_wrapper)

    on roles(:db), in: :sequence do
      within release_path do
        execute wrapper, "bundle", "exec", "bin/rails", "db:prepare"
      end
    end
  end
end

after "deploy:updated", "booking:db_prepare"

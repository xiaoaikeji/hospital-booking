require "shellwords"
require_relative "../release_history"

release_history = BookingCapistrano::ReleaseHistory

namespace :booking do
  task :mark_verified_release do
    next unless fetch(:booking_health_check_passed, false)

    on release_roles(:app) do
      execute :touch, release_path.join(release_history::VERIFIED_MARKER).to_s.shellescape
    end
  end
end

%w[finishing finishing_rollback rollback_release_path].each do |name|
  Rake::Task["deploy:#{name}"].clear_actions
end

namespace :deploy do
  task :finishing do
    if fetch(:booking_health_check_passed, false)
      invoke "deploy:cleanup"
    else
      puts "[deploy:cleanup] SKIPPED: services have not been verified on the new release."
    end
  end

  # The default rollback cleanup removes the newest directory, which may be unrelated to this rollback.
  task :finishing_rollback do
    invoke "deploy:finishing"
  end

  task :rollback_release_path do
    requested = ENV["ROLLBACK_RELEASE"]

    on release_roles(:app) do
      if fetch(:sshkit_backend) == SSHKit::Backend::Printer
        target = "verified-release"
        info "[deploy:rollback] dry-run: would select a previously verified release on the server."
      else
        current = File.basename(capture(:readlink, current_path.to_s.shellescape, raise_on_non_zero_exit: false))
        markers = capture(
          :find, releases_path.to_s.shellescape, "-mindepth", "2", "-maxdepth", "2",
          "-type", "f", "-name", release_history::VERIFIED_MARKER
        ).lines.map(&:chomp)
        target = release_history.rollback_target(current:, marker_paths: markers, requested:)

        unless target
          raise "没有可回滚的已验证版本。请核对当前版本及 ROLLBACK_RELEASE，目标须曾通过 Booking 的发布健康检查。"
        end
      end

      set_release_path(target)
      set :rollback_timestamp, target
    end
  end
end

before "deploy:published", "booking:mark_verified_release"

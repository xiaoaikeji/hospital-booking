# 每次发布切换 current 后重启 Booking 的 Web 与 Sidekiq 服务，再轮询 /up 确认 HTTP 200。
# 首次部署（systemd unit 尚未启动或需要先初始化账号）或维护窗口可传 SKIP_SYSTEMD_RESTART=1 跳过。
namespace :systemd do
  desc "Restart Booking web and jobs systemd units and verify both are active " \
       "(set SKIP_SYSTEMD_RESTART=1 to skip)"
  task :restart_web do
    web_unit = fetch(:booking_web_service)
    jobs_unit = fetch(:booking_jobs_service)
    use_sudo = fetch(:booking_systemd_use_sudo)

    if ENV["SKIP_SYSTEMD_RESTART"] == "1"
      puts "[systemd:restart_web] SKIPPED (SKIP_SYSTEMD_RESTART=1): " \
           "#{web_unit} / #{jobs_unit} were NOT restarted. " \
           "Restart them manually when ready: " \
           "systemctl restart #{web_unit} #{jobs_unit}"
      next
    end

    on roles(:app), in: :sequence do
      prefix = use_sudo ? [ :sudo, "-n" ] : []

      execute(*prefix, :systemctl, "restart", web_unit)
      execute(*prefix, :systemctl, "is-active", "--quiet", web_unit)

      execute(*prefix, :systemctl, "restart", jobs_unit)
      execute(*prefix, :systemctl, "is-active", "--quiet", jobs_unit)
    end
  end

  desc "Poll booking_health_check_url until it answers HTTP 200, with a bounded retry budget"
  task :health_check do
    web_unit = fetch(:booking_web_service)
    jobs_unit = fetch(:booking_jobs_service)
    health_check_url = fetch(:booking_health_check_url)
    use_sudo = fetch(:booking_systemd_use_sudo)

    if ENV["SKIP_SYSTEMD_RESTART"] == "1"
      puts "[systemd:health_check] SKIPPED (SKIP_SYSTEMD_RESTART=1): " \
           "the units were not restarted, so the post-restart health check " \
           "is skipped too."
      next
    end

    max_attempts = 10
    retry_pause = 2
    dry_run = fetch(:sshkit_backend) == SSHKit::Backend::Printer

    on roles(:app), in: :sequence do
      if dry_run
        execute :curl, "-s", "-o", "/dev/null", "-w", "'%{http_code}'",
                "--max-time", "5", health_check_url
        info "[systemd:health_check] dry-run: skipped real polling (would " \
             "try up to #{max_attempts} times, #{retry_pause}s apart)"
        next
      end

      attempt = 0
      loop do
        attempt += 1
        http_code = capture(
          :curl, "-s", "-o", "/dev/null", "-w", "'%{http_code}'",
          "--max-time", "5", health_check_url,
          raise_on_non_zero_exit: false
        ).to_s.strip

        if http_code == "200"
          info "[systemd:health_check] OK: #{health_check_url} " \
               "answered HTTP 200 (attempt #{attempt}/#{max_attempts})"
          break
        end

        if attempt >= max_attempts
          prefix = use_sudo ? [ :sudo, "-n" ] : []
          error "[systemd:health_check] FAILED: #{health_check_url} " \
                "did not answer HTTP 200 after #{max_attempts} attempts " \
                "(last code: #{http_code.empty? ? 'no response' : http_code})." \
                " Recent journal for both units follows:"
          execute(*prefix, :journalctl, "-u", web_unit, "-n", "30",
                  "--no-pager", raise_on_non_zero_exit: false)
          execute(*prefix, :journalctl, "-u", jobs_unit, "-n", "30",
                  "--no-pager", raise_on_non_zero_exit: false)
          raise "[systemd:health_check] #{health_check_url} still " \
                "not healthy after #{max_attempts} attempts; deploy failed. " \
                "The new release IS already published — inspect the server " \
                "manually (no automatic rollback is performed)."
        end

        sleep retry_pause
      end
    end
  end
end

after "deploy:publishing", "systemd:restart_web"
after "systemd:restart_web", "systemd:health_check"

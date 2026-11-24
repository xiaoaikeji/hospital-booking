require "shellwords"
require_relative "../deploy_verifier"

# 每次发布切换 current 后重启 Booking 的 Web 与 Sidekiq 服务，再联合校验 /up 与 /up/deploy。
# 维护窗口可传 SKIP_SYSTEMD_RESTART=1 跳过重启与验证。
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

      restarted_at_raw = capture(:date, "+%s").to_s.strip
      set :booking_restart_started_at, (restarted_at_raw.empty? ? nil : restarted_at_raw.to_i)

      execute(*prefix, :systemctl, "restart", jobs_unit)
    end
  end

  desc "Poll /up and /up/deploy until Booking release, DB readability, and fresh Sidekiq are verified"
  task :health_check do
    set :booking_health_check_passed, false

    web_unit = fetch(:booking_web_service)
    jobs_unit = fetch(:booking_jobs_service)
    up_url = fetch(:booking_health_check_url)
    deploy_url = BookingCapistrano::DeployVerifier.deploy_check_url(up_url)
    use_sudo = fetch(:booking_systemd_use_sudo)

    if ENV["SKIP_SYSTEMD_RESTART"] == "1"
      puts "[systemd:health_check] SKIPPED (SKIP_SYSTEMD_RESTART=1): " \
           "the units were not restarted, so the post-restart health check " \
           "is skipped too."
      next
    end

    max_attempts = 15
    retry_pause = 2
    dry_run = fetch(:sshkit_backend) == SSHKit::Backend::Printer
    expected_release = release_path.basename.to_s
    restarted_at = fetch(:booking_restart_started_at, nil)
    curl_options = [ "-s", "--noproxy", "'*'", "--max-time", "5" ]
    up_arguments = curl_options + [ "-o", "/dev/null", "-w", "'%{http_code}'", up_url.shellescape ]
    deploy_arguments = curl_options + [ "-w", "'\\n%{http_code}'", deploy_url.shellescape ]

    on roles(:app), in: :sequence do
      prefix = use_sudo ? [ :sudo, "-n" ] : []

      if dry_run
        execute :curl, *up_arguments
        execute :curl, *deploy_arguments
        execute(*prefix, :systemctl, "is-active", "--quiet", jobs_unit)
        execute(*prefix, :systemctl, "show", "-p", "MainPID", "--value", jobs_unit)
        set :booking_health_check_passed, true
        info "[systemd:health_check] dry-run: skipped real polling (would verify /up, #{deploy_url}, and live #{jobs_unit} MainPID/heartbeat for release #{expected_release})"
        next
      end

      expected_revision = fetch(:current_revision).to_s.strip
      if expected_revision.empty? && test("[ -f #{release_path.join('REVISION')} ]")
        expected_revision = capture(:cat, release_path.join("REVISION")).to_s.strip
      end

      attempt = 0
      last_reason = "no verification attempt executed"
      loop do
        attempt += 1
        up_code = capture(:curl, *up_arguments, raise_on_non_zero_exit: false).to_s.strip
        deploy_raw = capture(:curl, *deploy_arguments, raise_on_non_zero_exit: false)
        deploy_body, deploy_code = BookingCapistrano::DeployVerifier.parse_curl_output(deploy_raw)

        jobs_active = test(*prefix, :systemctl, "is-active", "--quiet", jobs_unit)
        jobs_pid_raw = capture(
          *prefix, :systemctl, "show", "-p", "MainPID", "--value", jobs_unit,
          raise_on_non_zero_exit: false
        ).to_s.strip
        current_jobs_pid = jobs_pid_raw.match?(/\A\d+\z/) ? jobs_pid_raw.to_i : 0

        result = BookingCapistrano::DeployVerifier.verify(
          up_http_code: up_code,
          deploy_http_code: deploy_code,
          deploy_body:,
          expected_release:,
          expected_revision:,
          expected_jobs_pid: current_jobs_pid,
          jobs_service_active: jobs_active,
          restarted_at:
        )

        if result.ok?
          set :booking_health_check_passed, true
          info "[systemd:health_check] OK (#{attempt}/#{max_attempts}): #{result.summary}"
          break
        end

        last_reason = result.reason

        if attempt >= max_attempts
          error "[systemd:health_check] FAILED after #{max_attempts} attempts: #{last_reason}. Recent journal for both units follows:"
          execute(*prefix, :journalctl, "-u", web_unit, "-n", "30",
                  "--no-pager", raise_on_non_zero_exit: false)
          execute(*prefix, :journalctl, "-u", jobs_unit, "-n", "30",
                  "--no-pager", raise_on_non_zero_exit: false)
          raise "[systemd:health_check] deploy verification failed (#{last_reason}). " \
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

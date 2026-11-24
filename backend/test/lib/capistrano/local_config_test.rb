# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "net/ssh"
require "open3"
require "sshkit"
require "tmpdir"
require_relative "../../../lib/capistrano/local_config"

class BookingCapistranoLocalConfigTest < Minitest::Test
  def test_missing_ssh_target_and_deploy_to_aborts_locally_with_example_instructions
    with_fake_repo(origin: "https://example.com/hospital/booking.git") do |backend_root|
      error = assert_raises(BookingCapistrano::LocalConfig::Error) do
        BookingCapistrano::LocalConfig.load!(stage: :production, backend_root:, env: {})
      end

      assert_includes error.message, "建立 SSH 连接前中止"
      assert_includes error.message, "ssh_target"
      assert_includes error.message, "deploy_to"
      assert_includes error.message, "production.local.yml.example"
    end
  end

  def test_defaults_repo_url_from_git_origin_and_uses_generic_booking_defaults
    with_fake_repo(origin: "https://example.com/hospital/booking.git") do |backend_root|
      config = BookingCapistrano::LocalConfig.load!(
        stage: :production,
        backend_root:,
        env: {
          "DEPLOY_SSH_TARGET" => "hospital-booking",
          "DEPLOY_TO" => "/home/booking.capistrano"
        }
      )

      assert_equal "hospital-booking", config.ssh_target
      assert_equal "/home/booking.capistrano", config.deploy_to
      assert_equal "https://example.com/hospital/booking.git", config.repo_url
      assert_equal "main", config.branch
      assert_equal "booking.web.service", config.web_service
      assert_equal "booking.jobs.service", config.jobs_service
      assert_equal "/usr/local/bin/booking-cap", config.cap_wrapper
      assert_equal "http://127.0.0.1:3000/up", config.health_check_url
      assert_equal false, config.systemd_use_sudo
    end
  end

  def test_detects_git_origin_when_dot_git_is_a_worktree_pointer_file
    Dir.mktmpdir do |tmpdir|
      main_repo = File.join(tmpdir, "main-repo")
      worktree_repo = File.join(tmpdir, "worktree-repo")
      FileUtils.mkdir_p(File.join(main_repo, "backend"))

      run_git!(main_repo, "init", "-b", "main")
      run_git!(main_repo, "config", "user.name", "Test")
      run_git!(main_repo, "config", "user.email", "test@example.invalid")
      File.write(File.join(main_repo, "README.md"), "test\n")
      run_git!(main_repo, "add", "README.md")
      run_git!(main_repo, "commit", "-m", "init")
      run_git!(main_repo, "remote", "add", "origin", "https://example.com/hospital/worktree-booking.git")
      run_git!(main_repo, "worktree", "add", "-b", "feature/test", worktree_repo)

      config = BookingCapistrano::LocalConfig.load!(
        stage: :production,
        backend_root: File.join(worktree_repo, "backend"),
        env: {
          "DEPLOY_SSH_TARGET" => "hospital-booking",
          "DEPLOY_TO" => "/home/booking.capistrano"
        }
      )

      assert_equal "https://example.com/hospital/worktree-booking.git", config.repo_url
    end
  end

  def test_non_git_directory_requires_manual_repo_url_and_accepts_yaml_override
    Dir.mktmpdir do |tmpdir|
      backend_root = File.join(tmpdir, "backend")
      FileUtils.mkdir_p(File.join(backend_root, "config/deploy"))

      error = assert_raises(BookingCapistrano::LocalConfig::Error) do
        BookingCapistrano::LocalConfig.load!(
          stage: :production,
          backend_root:,
          env: {
            "DEPLOY_SSH_TARGET" => "hospital-booking",
            "DEPLOY_TO" => "/home/booking.capistrano"
          }
        )
      end

      assert_includes error.message, "repo_url"

      File.write(
        File.join(backend_root, "config/deploy/production.local.yml"),
        <<~YAML
          ssh_target: hospital-booking
          deploy_to: /srv/booking
          repo_url: https://example.com/hospital/archive-booking.git
        YAML
      )

      config = BookingCapistrano::LocalConfig.load!(stage: :production, backend_root:, env: {})
      assert_equal "https://example.com/hospital/archive-booking.git", config.repo_url
      assert_equal "/srv/booking", config.deploy_to
    end
  end

  def test_env_variables_override_yaml_settings_and_support_custom_service_names
    with_fake_repo(origin: "https://example.com/hospital/booking.git") do |backend_root|
      File.write(
        File.join(backend_root, "config/deploy/production.local.yml"),
        <<~YAML
          ssh_target: yaml-alias
          deploy_to: /srv/yaml-booking
          branch: release
          web_service: custom-web.service
          jobs_service: custom-jobs.service
          health_check_url: http://127.0.0.1:4000/up
          systemd_use_sudo: false
        YAML
      )

      config = BookingCapistrano::LocalConfig.load!(
        stage: :production,
        backend_root:,
        env: {
          "DEPLOY_SSH_TARGET" => "env-alias",
          "DEPLOY_BRANCH" => "main",
          "DEPLOY_WEB_SERVICE" => "hospital-booking.web.service",
          "DEPLOY_JOBS_SERVICE" => "hospital-booking.jobs.service",
          "DEPLOY_CAP_WRAPPER" => "/opt/bin/booking-cap",
          "DEPLOY_HEALTH_CHECK_URL" => "http://127.0.0.1:3100/up",
          "DEPLOY_SYSTEMD_USE_SUDO" => "1"
        }
      )

      assert_equal "env-alias", config.ssh_target
      assert_equal "/srv/yaml-booking", config.deploy_to
      assert_equal "main", config.branch
      assert_equal "hospital-booking.web.service", config.web_service
      assert_equal "hospital-booking.jobs.service", config.jobs_service
      assert_equal "/opt/bin/booking-cap", config.cap_wrapper
      assert_equal "http://127.0.0.1:3100/up", config.health_check_url
      assert_equal true, config.systemd_use_sudo
    end
  end

  def test_rejects_invalid_configuration_formats_before_ssh
    with_fake_repo(origin: "https://example.com/hospital/booking.git") do |backend_root|
      error = assert_raises(BookingCapistrano::LocalConfig::Error) do
        BookingCapistrano::LocalConfig.load!(
          stage: :production,
          backend_root:,
          env: {
            "DEPLOY_SSH_TARGET" => "ssh bad-host",
            "DEPLOY_TO" => "relative/path",
            "DEPLOY_WEB_SERVICE" => "bad;service",
            "DEPLOY_CAP_WRAPPER" => "relative/wrapper",
            "DEPLOY_HEALTH_CHECK_URL" => "ftp://127.0.0.1/up",
            "DEPLOY_SYSTEMD_USE_SUDO" => "maybe"
          }
        )
      end

      assert_includes error.message, "ssh_target 不能包含空格"
      assert_includes error.message, "deploy_to 必须是无空格的服务器绝对路径"
      assert_includes error.message, "web_service 服务名格式无效"
      assert_includes error.message, "cap_wrapper 必须是无空格的绝对路径"
      assert_includes error.message, "health_check_url 必须是有效的"
      assert_includes error.message, "systemd_use_sudo 仅支持"
    end
  end

  def test_ssh_alias_leaves_user_port_and_keys_unset_for_ssh_config_inheritance
    Dir.mktmpdir do |tmpdir|
      ssh_config_path = File.join(tmpdir, "ssh_config")
      key_path = File.join(tmpdir, "hospital_ed25519")
      File.write(key_path, "dummy-key\n")
      File.write(
        ssh_config_path,
        <<~CONFIG
          Host hospital-alias
            HostName 203.0.113.10
            User deploy
            Port 2222
            IdentityFile #{key_path}
        CONFIG
      )

      host = SSHKit::Host.new("hospital-alias")
      assert_equal "hospital-alias", host.hostname
      assert_nil host.username
      assert_nil host.port
      assert_empty host.keys

      resolved = Net::SSH.configuration_for(host.hostname, [ ssh_config_path ]).merge(host.netssh_options)
      assert_equal "203.0.113.10", resolved[:host_name]
      assert_equal "deploy", resolved[:user]
      assert_equal 2222, resolved[:port]
      assert_includes resolved[:keys], key_path
    end
  end

  def test_health_check_target_must_be_a_loopback_url_before_ssh
    with_fake_repo(origin: "https://example.com/hospital/booking.git") do |backend_root|
      env = { "DEPLOY_SSH_TARGET" => "hospital-booking", "DEPLOY_TO" => "/srv/booking" }
      error = assert_raises(BookingCapistrano::LocalConfig::Error) do
        BookingCapistrano::LocalConfig.load!(
          stage: :production, backend_root:, env: env.merge("DEPLOY_HEALTH_CHECK_URL" => "https://booking.example.org/up")
        )
      end
      assert_includes error.message, "服务器本机回环"

      url = "http://[::1]:3100/up"
      config = BookingCapistrano::LocalConfig.load!(
        stage: :production, backend_root:, env: env.merge("DEPLOY_HEALTH_CHECK_URL" => url)
      )
      assert_equal url, config.health_check_url
    end
  end

  def test_supports_optional_linked_files_and_rejects_unsafe_paths
    with_fake_repo(origin: "https://example.com/hospital/booking.git") do |backend_root|
      File.write(
        File.join(backend_root, "config/deploy/production.local.yml"),
        <<~YAML
          ssh_target: hospital-booking
          deploy_to: /home/booking.capistrano
          linked_files:
            - config/credentials.yml.enc
        YAML
      )

      config = BookingCapistrano::LocalConfig.load!(stage: :production, backend_root:, env: {})
      assert_equal [ "config/credentials.yml.enc" ], config.linked_files

      %w[/etc/passwd ../secret config/../master.key].each do |unsafe_path|
        error = assert_raises(BookingCapistrano::LocalConfig::Error) do
          BookingCapistrano::LocalConfig.load!(
            stage: :production,
            backend_root:,
            env: { "DEPLOY_LINKED_FILES" => unsafe_path }
          )
        end
        assert_includes error.message, "linked_files 只能填写"
      end
    end
  end

  private

  def with_fake_repo(origin: nil)
    Dir.mktmpdir do |tmpdir|
      backend_root = File.join(tmpdir, "backend")
      FileUtils.mkdir_p(File.join(backend_root, "config/deploy"))
      run_git!(tmpdir, "init", "-b", "main")
      run_git!(tmpdir, "remote", "add", "origin", origin) if origin
      yield backend_root
    end
  end

  def run_git!(dir, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{stdout}\n#{stderr}" unless status.success?
  end
end

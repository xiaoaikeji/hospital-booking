# frozen_string_literal: true

require "open3"
require "uri"
require "yaml"

module BookingCapistrano
  # Loads and validates deployer-local Capistrano settings before any SSH connection opens.
  class LocalConfig
    class Error < StandardError; end

    DEFAULT_BRANCH = "main"
    DEFAULT_WEB_SERVICE = "booking.web.service"
    DEFAULT_JOBS_SERVICE = "booking.jobs.service"
    DEFAULT_CAP_WRAPPER = "/usr/local/bin/booking-cap"
    DEFAULT_HEALTH_CHECK_URL = "http://127.0.0.1:3000/up"

    UNIT_NAME_PATTERN = /\A[A-Za-z0-9@_.-]+\z/
    ABS_NO_SPACE_PATTERN = /\A\/\S+\z/
    LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze
    REL_FILE_PATTERN = /\A[A-Za-z0-9_.\-\/]+\z/

    Config = Data.define(
      :ssh_target,
      :deploy_to,
      :repo_url,
      :branch,
      :web_service,
      :jobs_service,
      :cap_wrapper,
      :health_check_url,
      :systemd_use_sudo,
      :linked_files,
      :config_path
    )

    def self.load!(stage:, backend_root:, env: ENV, config_path: nil)
      new(stage:, backend_root:, env:, config_path:).load!
    end

    def initialize(stage:, backend_root:, env: ENV, config_path: nil)
      @stage = stage.to_s
      @backend_root = File.expand_path(backend_root.to_s)
      @env = env
      @explicit_config_path = normalize_string(config_path)
      @env_config_path = normalize_string(@env["DEPLOY_CONFIG_FILE"])
    end

    def load!
      path = resolve_config_path
      yaml_values = load_yaml_file(path)

      ssh_target = pick_string("DEPLOY_SSH_TARGET", yaml_values["ssh_target"])
      deploy_to = pick_string("DEPLOY_TO", yaml_values["deploy_to"])
      repo_url = pick_string("DEPLOY_REPO_URL", yaml_values["repo_url"]) || detect_origin_url
      branch = pick_string("DEPLOY_BRANCH", yaml_values["branch"]) || DEFAULT_BRANCH
      web_service = pick_string("DEPLOY_WEB_SERVICE", yaml_values["web_service"]) || DEFAULT_WEB_SERVICE
      jobs_service = pick_string("DEPLOY_JOBS_SERVICE", yaml_values["jobs_service"]) || DEFAULT_JOBS_SERVICE
      cap_wrapper = pick_string("DEPLOY_CAP_WRAPPER", yaml_values["cap_wrapper"]) || DEFAULT_CAP_WRAPPER
      health_check_url = pick_string("DEPLOY_HEALTH_CHECK_URL", yaml_values["health_check_url"]) || DEFAULT_HEALTH_CHECK_URL
      systemd_use_sudo, sudo_error = resolve_boolean("DEPLOY_SYSTEMD_USE_SUDO", yaml_values["systemd_use_sudo"], default: false)
      linked_files, linked_files_error = resolve_linked_files("DEPLOY_LINKED_FILES", yaml_values["linked_files"])

      validate!(
        ssh_target:,
        deploy_to:,
        repo_url:,
        branch:,
        web_service:,
        jobs_service:,
        cap_wrapper:,
        health_check_url:,
        sudo_error:,
        linked_files:,
        linked_files_error:
      )

      Config.new(
        ssh_target:,
        deploy_to:,
        repo_url:,
        branch:,
        web_service:,
        jobs_service:,
        cap_wrapper:,
        health_check_url:,
        systemd_use_sudo:,
        linked_files:,
        config_path: path
      )
    end

    private

    attr_reader :stage, :backend_root, :env, :explicit_config_path, :env_config_path

    def resolve_config_path
      if explicit_config_path
        File.expand_path(explicit_config_path, backend_root)
      elsif env_config_path
        expanded = File.expand_path(env_config_path, backend_root)
        unless File.file?(expanded)
          raise Error, "部署配置无效，已在建立 SSH 连接前中止。\n- DEPLOY_CONFIG_FILE 指向的文件不存在：#{expanded}"
        end

        expanded
      else
        File.join(backend_root, "config", "deploy", "#{stage}.local.yml")
      end
    end

    def load_yaml_file(path)
      return {} unless File.file?(path)

      parsed = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      return {} if parsed.nil?

      unless parsed.is_a?(Hash)
        raise Error, "部署配置无效，已在建立 SSH 连接前中止。\n- 配置文件顶层必须是 YAML 映射（key: value）：#{path}"
      end

      parsed.transform_keys(&:to_s)
    rescue Psych::SyntaxError => e
      raise Error, "部署配置无效，已在建立 SSH 连接前中止。\n- 配置文件 YAML 语法错误（#{path}）：#{e.message}"
    end

    def pick_string(env_key, yaml_value)
      env_val = normalize_string(env[env_key])
      return env_val unless env_val.nil?

      normalize_string(yaml_value)
    end

    def normalize_string(value)
      return nil if value.nil?

      str = value.to_s.strip
      str.empty? ? nil : str
    end

    def resolve_boolean(env_key, yaml_value, default:)
      raw = env.key?(env_key) && !env[env_key].to_s.strip.empty? ? env[env_key] : yaml_value
      return [ default, nil ] if raw.nil? || raw.to_s.strip.empty?
      return [ raw, nil ] if raw == true || raw == false

      case raw.to_s.strip.downcase
      when "1", "true"
        [ true, nil ]
      when "0", "false"
        [ false, nil ]
      else
        [ default, "systemd_use_sudo 仅支持 true / false（或环境变量 1 / 0），当前值为 #{raw.inspect}" ]
      end
    end

    def resolve_linked_files(env_key, yaml_value)
      raw_env = env[env_key]
      if env.key?(env_key) && !raw_env.to_s.strip.empty?
        entries = raw_env.to_s.split(",").map(&:strip).reject(&:empty?)
        return [ entries.freeze, nil ]
      end

      return [ [].freeze, nil ] if yaml_value.nil?
      unless yaml_value.is_a?(Array)
        return [ [].freeze, "linked_files 必须是相对路径列表，例如 [config/credentials.yml.enc]" ]
      end

      entries = yaml_value.map { |item| item.to_s.strip }.reject(&:empty?)
      [ entries.freeze, nil ]
    end

    def detect_origin_url
      repo_root = File.expand_path("..", backend_root)
      return nil unless File.exist?(File.join(repo_root, ".git"))

      stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "remote", "get-url", "origin")
      return nil unless status.success?

      normalize_string(stdout)
    rescue Errno::ENOENT
      nil
    end

    def validate!(ssh_target:, deploy_to:, repo_url:, branch:, web_service:, jobs_service:, cap_wrapper:, health_check_url:, sudo_error:, linked_files:, linked_files_error:)
      missing = []
      invalid = []

      missing << "ssh_target（SSH 目标，支持 ~/.ssh/config 别名或 user@host）" if ssh_target.nil?
      missing << "deploy_to（服务器发布绝对路径，例如 /home/booking.capistrano）" if deploy_to.nil?
      missing << "repo_url（源码仓库地址；未检测到 Git origin，请手动填写）" if repo_url.nil?

      if ssh_target&.match?(/\s/)
        invalid << "ssh_target 不能包含空格，请填写 SSH 别名或 user@host（不要写成 \"ssh ...\"）"
      end
      if deploy_to && !deploy_to.match?(ABS_NO_SPACE_PATTERN)
        invalid << "deploy_to 必须是无空格的服务器绝对路径，例如 /home/booking.capistrano"
      end
      if repo_url&.match?(/\s/)
        invalid << "repo_url 不能包含空格"
      end
      if branch.match?(/\s/)
        invalid << "branch 不能包含空格"
      end
      unless web_service.match?(UNIT_NAME_PATTERN)
        invalid << "web_service 服务名格式无效，仅允许字母、数字、@、_、.、-"
      end
      unless jobs_service.match?(UNIT_NAME_PATTERN)
        invalid << "jobs_service 服务名格式无效，仅允许字母、数字、@、_、.、-"
      end
      unless cap_wrapper.match?(ABS_NO_SPACE_PATTERN)
        invalid << "cap_wrapper 必须是无空格的绝对路径，例如 /usr/local/bin/booking-cap"
      end
      unless valid_health_check_url?(health_check_url)
        invalid << "health_check_url 必须是有效的服务器本机回环 HTTP(S) 地址，例如 http://127.0.0.1:3000/up"
      end
      invalid << sudo_error if sudo_error
      invalid << linked_files_error if linked_files_error
      linked_files.each do |entry|
        if !entry.match?(REL_FILE_PATTERN) || entry.start_with?("/") || entry.end_with?("/") || entry.split("/").include?("..")
          invalid << "linked_files 只能填写不含空格、不以 / 开头且不包含 .. 的相对路径：#{entry.inspect}"
        end
      end

      return if missing.empty? && invalid.empty?

      raise Error, build_error_message(missing:, invalid:, include_repo_hint: repo_url.nil?)
    end

    def valid_health_check_url?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && LOOPBACK_HOSTS.include?(uri.hostname) && uri.userinfo.nil? &&
        (1..65_535).cover?(uri.port)
    rescue URI::Error
      false
    end

    def build_error_message(missing:, invalid:, include_repo_hint:)
      header = missing.any? && invalid.empty? ? "部署配置不完整，已在建立 SSH 连接前中止。" : "部署配置无效，已在建立 SSH 连接前中止。"
      lines = [ header ]

      if missing.any?
        lines << ""
        lines << "缺少配置："
        missing.each { |item| lines << "  - #{item}" }
      end

      if invalid.any?
        lines << ""
        lines << "格式错误："
        invalid.each { |item| lines << "  - #{item}" }
      end

      example_rel = "config/deploy/#{stage}.local.yml.example"
      example_rel = "config/deploy/production.local.yml.example" unless File.file?(File.join(backend_root, example_rel))
      local_rel = "config/deploy/#{stage}.local.yml"
      lines << ""
      lines << "请先在 backend/ 准备本机部署配置（已加入 .gitignore，不会提交到仓库）："
      lines << "  cp #{example_rel} #{local_rel}"
      lines << "至少填写："
      lines << "  ssh_target: your-ssh-alias-or-user@host"
      lines << "  deploy_to: /home/booking.capistrano"
      lines << "  repo_url: https://example.com/your-org/hospital-booking.git" if include_repo_hint
      lines << "也可以通过环境变量 DEPLOY_SSH_TARGET、DEPLOY_TO#{include_repo_hint ? '、DEPLOY_REPO_URL' : ''} 传入。"
      lines << "详细步骤见仓库 docs/setup/部署与配置.md。"
      lines.join("\n")
    end
  end
end

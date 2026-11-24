# frozen_string_literal: true

module Admins
  # Creates the initial super admin via CLI while enforcing explicit non-default passwords in production.
  class InitialCreator
    class Error < StandardError; end

    def initialize(env: ENV, input: $stdin, output: $stdout, error_output: $stderr, production: Rails.env.production?)
      @env = env
      @input = input
      @output = output
      @error_output = error_output
      @production = production
    end

    def call
      raise Error, "管理员已存在，请在后台管理账号" if Admin.exists?

      username = resolve_username
      password = resolve_password

      Admin.transaction do
        admin = Admin.create!(username:, password:, role: "super_admin", name: "超级管理员")
        Log.record!(action: "admin.create", category: "security", actor: admin, target: admin, source: "console")
        output.puts "已创建超级管理员：#{admin.username}"
        admin
      end
    rescue ActiveRecord::RecordInvalid => e
      raise Error, "创建超级管理员失败：#{e.record.errors.full_messages.join('；')}"
    end

    private

    attr_reader :env, :input, :output, :error_output, :production

    def resolve_username
      env["ADMIN_USERNAME"].to_s.strip.presence || "admin"
    end

    def resolve_password
      return env["ADMIN_PASSWORD"].presence || Admin::DEFAULT_PASSWORD unless production

      password = if env.key?("ADMIN_PASSWORD")
        env["ADMIN_PASSWORD"].to_s
      elsif input.respond_to?(:tty?) && input.tty?
        read_interactive_password
      else
        input.gets&.chomp
      end

      validate_production_password!(password)
      password
    end

    def read_interactive_password
      require "io/console"

      error_output.print("请输入首个超级管理员密码（不回显）：")
      password = input.noecho(&:gets)&.chomp
      error_output.puts
      validate_production_password!(password)

      error_output.print("请再次输入密码确认（不回显）：")
      confirmation = input.noecho(&:gets)&.chomp
      error_output.puts
      raise Error, "两次输入的密码不一致，已取消创建" if password != confirmation

      password
    end

    def validate_production_password!(password)
      if password.nil? || password.strip.empty?
        raise Error, "生产环境创建首个超级管理员必须显式设置密码，不能为空或全空白"
      end
      if password == Admin::DEFAULT_PASSWORD || password.strip == Admin::DEFAULT_PASSWORD
        raise Error, "生产环境禁止使用公开默认密码，请设置独立密码"
      end
      if password.length < 6 || password.length > 128
        raise Error, "管理员密码长度须为 6 到 128 位"
      end
    end
  end
end

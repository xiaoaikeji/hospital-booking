# frozen_string_literal: true

require "json"
require "uri"

module BookingCapistrano
  # Verifies post-restart /up and /up/deploy responses against the deployed Booking release and fresh Sidekiq process.
  class DeployVerifier
    APP_NAME = "booking"
    DEFAULT_REQUIRED_QUEUES = %w[default].freeze

    Result = Data.define(:ok, :reason, :summary) do
      def ok? = ok
    end

    def self.deploy_check_url(health_check_url)
      uri = URI.parse(health_check_url.to_s)
      uri.path = "/up/deploy"
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    end

    def self.parse_curl_output(raw)
      text = raw.to_s
      return [ "", "" ] if text.empty?

      trimmed = text.sub(/\r?\n\z/, "")
      if (newline_idx = trimmed.rindex("\n"))
        [ trimmed[0...newline_idx], trimmed[(newline_idx + 1)..].to_s.strip ]
      elsif trimmed.match?(/\A\d{3}\z/)
        [ "", trimmed ]
      else
        [ trimmed, "" ]
      end
    end

    def self.verify(
      up_http_code:,
      deploy_http_code:,
      deploy_body:,
      expected_release:,
      expected_revision: nil,
      expected_jobs_pid: nil,
      restarted_at: nil,
      required_queues: DEFAULT_REQUIRED_QUEUES
    )
      up_code = up_http_code.to_s.strip
      unless up_code == "200"
        return fail_result("/up 返回 #{code_label(up_code)}，预期 200")
      end

      deploy_code = deploy_http_code.to_s.strip
      unless deploy_code == "200"
        return fail_result("/up/deploy 返回 #{code_label(deploy_code)}，无法确认新发布的 Booking 进程与数据库连接")
      end

      payload = parse_json_hash(deploy_body)
      return fail_result("/up/deploy 响应不是有效的 JSON 对象") unless payload

      if payload["app"].to_s != APP_NAME
        return fail_result("/up/deploy 所属应用为 #{payload['app'].inspect}，预期 #{APP_NAME}")
      end

      if payload["release"].to_s != expected_release.to_s
        return fail_result("Web 进程仍运行版本 #{payload['release'].inspect}，预期 #{expected_release}")
      end

      expected_rev = expected_revision.to_s.strip
      if !expected_rev.empty? && payload["revision"].to_s != expected_rev
        return fail_result("Web 进程代码版本为 #{payload['revision'].inspect}，预期 #{expected_rev}")
      end

      unless payload["database"] == "ok"
        return fail_result("数据库读取检查失败（database=#{payload['database'].inspect}）")
      end

      unless payload.dig("sidekiq", "ok") == true
        return fail_result("Sidekiq 任务队列状态读取失败")
      end

      verify_sidekiq_process(
        processes: Array(payload.dig("sidekiq", "processes")),
        expected_release:,
        expected_jobs_pid:,
        restarted_at:,
        required_queues:
      )
    end

    class << self
      private

      def verify_sidekiq_process(processes:, expected_release:, expected_jobs_pid:, restarted_at:, required_queues:)
        expected_tag = "#{APP_NAME}:#{expected_release}"
        required = Array(required_queues).map(&:to_s)
        expected_pid = expected_jobs_pid.to_i

        matched = processes.find do |proc|
          next false unless proc.is_a?(Hash)
          next false unless proc["tag"].to_s == expected_tag
          next false unless proc["stopping"] == false
          next false if expected_pid.positive? && proc["pid"].to_i != expected_pid
          next false if restarted_at && proc["started_at"].to_f < restarted_at.to_f - 2.0
          next false unless proc["beat"].to_f.positive?

          (required - Array(proc["queues"]).map(&:to_s)).empty?
        end

        if matched
          return Result.new(
            ok: true,
            reason: nil,
            summary: "app=#{APP_NAME} release=#{expected_release} db=ok sidekiq_pid=#{matched['pid']}"
          )
        end

        if processes.empty?
          return fail_result("Booking Sidekiq（#{expected_tag}）尚未向任务队列注册心跳")
        end

        seen = processes.map do |proc|
          next proc.inspect unless proc.is_a?(Hash)

          "pid=#{proc['pid']},tag=#{proc['tag']},stopping=#{proc['stopping']},started_at=#{proc['started_at']},queues=#{Array(proc['queues']).join(',')}"
        end.join("; ")

        fail_result(
          "未检测到本次新启动的 Booking Sidekiq 心跳（预期 tag=#{expected_tag}" \
          "#{expected_pid.positive? ? ", pid=#{expected_pid}" : ''}；当前队列进程：#{seen}）"
        )
      end

      def parse_json_hash(raw)
        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def code_label(code)
        code.empty? ? "no response" : code
      end

      def fail_result(reason)
        Result.new(ok: false, reason:, summary: nil)
      end
    end
  end
end

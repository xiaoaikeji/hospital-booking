require "sidekiq/api"
require "sidekiq/cron/job"

# 只读 Sidekiq 快照；参数、错误消息、回溯永不进入返回值。
module BackgroundJobOverview
  RESULTS_KEY = "booking:background_jobs:cron_results"
  FAILURE_LIMIT = 20
  RETRY_SCAN_LIMIT = 1000
  Overview = Data.define(:queues, :scheduled, :retries, :dead, :processes, :cron_jobs, :failures, :captured_at)
  QueueCount = Data.define(:name, :waiting, :busy) do
    def label = I18n.t(name, scope: "background_jobs.queues", default: name)
  end
  ProcessInfo = Data.define(:hostname, :pid, :busy, :concurrency, :queues, :quiet, :heartbeat_at)
  CronJob = Data.define(:name, :label, :cron, :queue, :enqueued_at, :finished_at, :succeeded, :error_class)
  Failure = Data.define(:job_class, :queue, :state, :failed_at, :retry_count, :error_class)

  class << self
    def fetch
      stats = Sidekiq::Stats.new
      waiting = stats.queues
      busy = Sidekiq::WorkSet.new.each_with_object(Hash.new(0)) { |(_pid, _tid, work), counts| counts[work.queue] += 1 }
      queues = configured_queues.map do |name|
        QueueCount.new(name: name, waiting: waiting.fetch(name, 0), busy: busy[name])
      end
      # false 禁止 ProcessSet 在读取时顺带清理失联进程。
      processes = Sidekiq::ProcessSet.new(false).map do |process|
        ProcessInfo.new(hostname: process["hostname"], pid: process["pid"], busy: process["busy"].to_i,
          concurrency: process["concurrency"].to_i, queues: Array(process["queues"]), quiet: process.stopping?, heartbeat_at: time_at(process["beat"]))
      end
      failures = recent_failures(Sidekiq::RetrySet.new.first(RETRY_SCAN_LIMIT), "retry") +
        recent_failures(Sidekiq::DeadSet.new.first(FAILURE_LIMIT), "dead")
      Overview.new(queues: queues, scheduled: stats.scheduled_size, retries: stats.retry_size, dead: stats.dead_size,
        processes: processes, cron_jobs: cron_jobs, failures: failures.sort_by { |job| -job.failed_at.to_f }.first(FAILURE_LIMIT), captured_at: Time.current)
    end

    def recent_failures(records, state)
      records.map do |record|
        Failure.new(job_class: safe_class(record["wrapped"] || record["class"]), queue: record.queue.to_s,
          state: state, failed_at: (record.retried_at || record.failed_at)&.in_time_zone,
          retry_count: record["retry_count"].to_i, error_class: safe_class(record["error_class"]))
      end.sort_by { |job| -job.failed_at.to_f }.first(FAILURE_LIMIT)
    end

    def cron_jobs
      enqueue_times = Sidekiq::Cron::Job.all.to_h { |job| [ job.name, job.last_enqueue_time ] }
      results = Sidekiq.redis { |redis| redis.hgetall(RESULTS_KEY) }
      schedule.map do |name, attributes|
        result = parse_result(results[name])
        CronJob.new(name: name, label: attributes["description"].presence || I18n.t(name, scope: "background_jobs.cron", default: name),
          cron: attributes["cron"], queue: attributes.fetch("queue", "default"), enqueued_at: enqueue_times[name]&.in_time_zone,
          finished_at: result[:finished_at], succeeded: result[:succeeded], error_class: result[:error_class])
      end
    end

    def schedule = load_yaml("config/schedule.yml")

    def configured_queues
      config = load_yaml("config/sidekiq.yml")
      queues = Array(config["queues"]) + config.fetch("capsules", {}).to_h.values.flat_map { |capsule| Array(capsule["queues"]) }
      names = queues.map { |queue| Array(queue).first.to_s } + schedule.values.map { |job| job["queue"].presence || "default" }
      names.map(&:strip).reject(&:empty?).uniq
    end

    # 同类 Worker 被多个配置复用时按队列及参数区分，不能明确匹配就不误记到其他定时任务。
    def cron_name_for(job, queue)
      klass = job["wrapped"] || job["class"]
      args = job["wrapped"] ? job.dig("args", 0, "arguments") : job["args"]
      matches = schedule.select do |_name, attributes|
        attributes["class"] == klass && attributes.fetch("queue", "default") == queue && Array(attributes["args"]) == Array(args)
      end
      matches.keys.sole if matches.one?
    end

    def record_result(name, error = nil)
      result = { finished_at: Time.current.iso8601(6), succeeded: error.nil?, error_class: error&.class&.name }.compact
      write_result(name, result.to_json)
    rescue StandardError => record_error
      Rails.logger.warn("[background_jobs] result recording unavailable (#{record_error.class})")
    end

    def write_result(name, json)
      Sidekiq.redis { |redis| redis.hset(RESULTS_KEY, name, json) }
    end

    def parse_result(raw)
      result = JSON.parse(raw.to_s)
      return {} unless result.is_a?(Hash) && [ true, false ].include?(result["succeeded"]) && result["finished_at"].is_a?(String)
      { finished_at: Time.iso8601(result["finished_at"]).in_time_zone, succeeded: result["succeeded"], error_class: (safe_class(result["error_class"]) if result["error_class"].present?) }
    rescue JSON::ParserError, ArgumentError
      {}
    end

    private

    def load_yaml(path)
      YAML.safe_load(ERB.new(Rails.root.join(path).read).result, permitted_classes: [ Symbol ], aliases: true) || {}
    end

    def safe_class(value)
      value.to_s.match?(/\A[A-Za-z]\w*(?:::[A-Za-z]\w*)*\z/) ? value.to_s.first(160) : "UnknownError"
    end

    def time_at(value) = value.present? ? Time.zone.at(value.to_f) : nil
  end

  class CronResultRecorder
    include Sidekiq::ServerMiddleware

    def call(_worker, job, queue)
      name = BackgroundJobOverview.cron_name_for(job, queue)
      return yield unless name
      begin
        value = yield
      rescue StandardError => error
        BackgroundJobOverview.record_result(name, error)
        raise
      end
      BackgroundJobOverview.record_result(name)
      value
    end
  end
end

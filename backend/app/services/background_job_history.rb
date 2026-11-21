require "digest"

module BackgroundJobHistory
  HOURS = 24
  RETENTION = 48.hours.to_i
  SAMPLE_INTERVAL = 5.minutes.to_i
  ATTEMPTS_KEY = "booking:background_jobs:attempts"
  SAMPLE_PREFIX = "booking:background_jobs:queue_sample"

  Attempt = Data.define(:at, :job_key, :task, :worker, :queue, :error_class, :number)
  Failure = Data.define(:attempt, :recovered)
  Slot = Data.define(:hour, :state, :failures)
  Timeline = Data.define(:hours, :slots, :waiting, :busy, :failure_counts, :recent_failures)

  class << self
    def record(job, queue, task:, error: nil, at: Time.current)
      return if job["jid"].blank? || !(task || error || job.key?("retry_count"))

      timestamp = at.to_f
      attempt = {
        at: timestamp, job_key: Digest::SHA256.hexdigest(job["jid"]), task: task,
        worker: BackgroundJobOverview.safe_class(job["wrapped"] || job["class"]), queue: queue.to_s.first(80),
        error_class: (BackgroundJobOverview.safe_class(error.class.name) if error),
        number: job.fetch("retry_count", -1).to_i + 2
      }
      Sidekiq.redis do |redis|
        redis.multi do |transaction|
          transaction.zadd(ATTEMPTS_KEY, timestamp, attempt.to_json)
          transaction.zremrangebyscore(ATTEMPTS_KEY, "-inf", "(#{timestamp - RETENTION}")
          transaction.expire(ATTEMPTS_KEY, RETENTION)
        end
      end
    rescue StandardError => recording_error
      Rails.logger.warn("[background_jobs] history recording unavailable (#{recording_error.class})")
    end

    def sample_queue(at: Time.current)
      key = sample_key(at)
      return if @last_sample_key == key

      unless Sidekiq.redis { |redis| redis.exists(key).positive? }
        queues = BackgroundJobOverview.queue_counts
        value = [ queues.sum(&:waiting), queues.sum(&:busy) ].to_json
        Sidekiq.redis { |redis| redis.set(key, value, nx: true, ex: RETENTION) }
      end
      @last_sample_key = key
    rescue StandardError => sampling_error
      Rails.logger.warn("[background_jobs] queue sampling unavailable (#{sampling_error.class})")
    end

    def fetch(captured_at, task_names:)
      first_hour = captured_at.beginning_of_hour - (HOURS - 1).hours
      hours = Array.new(HOURS) { |index| first_hour + index.hours }
      sample_keys = hours.flat_map do |hour|
        (1.hour.to_i / SAMPLE_INTERVAL).times.filter_map do |index|
          time = hour + index * SAMPLE_INTERVAL
          sample_key(time) if time <= captured_at
        end
      end
      raw_attempts, raw_samples = Sidekiq.redis do |redis|
        redis.pipelined do |pipeline|
          pipeline.zrange(ATTEMPTS_KEY, first_hour.to_f, captured_at.to_f, "BYSCORE")
          pipeline.mget(*sample_keys)
        end
      end
      attempts = raw_attempts.filter_map { |raw| parse_attempt(raw) }
      samples = raw_samples.each_slice(1.hour.to_i / SAMPLE_INTERVAL).map do |slice|
        slice.reverse_each.lazy.filter_map { |raw| parse_sample(raw) }.first
      end
      build_timeline(hours, task_names, attempts, samples)
    end

    private

    def build_timeline(hours, task_names, attempts, samples)
      successes = attempts.reverse_each.with_object({}) do |attempt, latest|
        latest[attempt.job_key] ||= attempt.at unless attempt.error_class
      end
      failures = attempts.reverse_each.filter_map do |attempt|
        next unless attempt.error_class
        recovered_at = successes[attempt.job_key]
        Failure.new(attempt: attempt, recovered: recovered_at.present? && recovered_at > attempt.at)
      end
      by_hour = attempts.group_by { |attempt| attempt.at.beginning_of_hour }
      failures_by_hour = failures.group_by { |entry| entry.attempt.at.beginning_of_hour }
      by_task_hour = attempts.group_by { |attempt| [ attempt.task, attempt.at.beginning_of_hour ] }
      failures_by_task_hour = failures.group_by { |entry| [ entry.attempt.task, entry.attempt.at.beginning_of_hour ] }

      slots = task_names.index_with do |task|
        hours.map do |hour|
          entries = failures_by_task_hour.fetch([ task, hour ], [])
          state = if by_task_hour[[ task, hour ]].nil?
            :missing
          elsif entries.empty?
            :success
          elsif entries.all?(&:recovered)
            :recovered
          else
            :failed
          end
          Slot.new(hour: hour, state: state, failures: entries.first(BackgroundJobOverview::FAILURE_LIMIT))
        end
      end

      Timeline.new(hours: hours, slots: slots, waiting: samples.map { |sample| sample&.first }, busy: samples.map { |sample| sample&.last },
        failure_counts: hours.map.with_index { |hour, index| failures_by_hour.fetch(hour, []).size if samples[index].present? || by_hour.key?(hour) },
        recent_failures: failures.first(BackgroundJobOverview::FAILURE_LIMIT))
    end

    def sample_key(at) = "#{SAMPLE_PREFIX}:#{at.to_i / SAMPLE_INTERVAL}"

    def parse_sample(raw)
      return unless raw
      values = JSON.parse(raw)
      values if values.is_a?(Array) && values.size == 2 && values.all? { |value| value.is_a?(Integer) && value >= 0 }
    rescue JSON::ParserError
      nil
    end

    def parse_attempt(raw)
      data = JSON.parse(raw)
      return unless data.is_a?(Hash) && data["at"].is_a?(Numeric) && data["job_key"].is_a?(String)
      Attempt.new(at: Time.zone.at(data.fetch("at")), **data.symbolize_keys.except(:at))
    rescue JSON::ParserError, ArgumentError, RangeError
      nil
    end
  end
end

require "test_helper"

class BackgroundJobHistoryTest < ActiveSupport::TestCase
  class HistoryReader
    def initialize(attempts, samples)
      @attempts = attempts
      @samples = samples
    end

    def pipelined
      yield self
      [@attempts, @values]
    end

    def zrange(_key, _start, _finish, _by_score); end

    def mget(*keys)
      @values = keys.map { |key| @samples[key] }
    end
  end

  test "slots retain failures after a retry recovers and gaps stay absent" do
    original_redis = Sidekiq.method(:redis)
    now = Time.zone.local(2026, 11, 21, 9, 12)
    key = ->(at) { "#{BackgroundJobHistory::SAMPLE_PREFIX}:#{at.to_i / BackgroundJobHistory::SAMPLE_INTERVAL}" }
    task = "notification_delivery"
    attempts = [
      attempt(now - 2.hours, "retrying", task, "Net::ReadTimeout"),
      attempt(now - 1.hour, "retrying", task, nil, number: 2),
      attempt(now - 4.minutes, "still-failed", task, "Net::OpenTimeout"),
      attempt(now - 3.minutes, "other", nil, "ArgumentError"),
      "invalid entry"
    ]
    reader = HistoryReader.new(attempts, { key.call(now - 1.hour) => "[5,1]", key.call(now - 2.minutes) => "[9,2]",
      key.call(now + 10.minutes) => "[78,4]" })
    Sidekiq.define_singleton_method(:redis) { |&operation| operation.call(reader) }

    history = BackgroundJobHistory.fetch(now, task_names: [task])
    assert_equal 24, history.hours.size
    assert_equal [:missing, :recovered, :success, :failed], history.slots.fetch(task).last(4).map(&:state)
    assert_equal [nil, nil, 5, 9], history.waiting.last(4)
    assert_equal [nil, 1, 0, 2], history.failure_counts.last(4)
    assert_equal ["ArgumentError", "Net::OpenTimeout", "Net::ReadTimeout"], history.recent_failures.map { |event| event.attempt.error_class }
    assert history.slots.fetch(task)[-3].failures.sole.recovered
  ensure
    Sidekiq.define_singleton_method(:redis, original_redis)
  end

  test "recording an exception retains only safe execution metadata" do
    original_redis = Sidekiq.method(:redis)
    transaction = Object.new
    writes = []
    transaction.define_singleton_method(:multi) { |&operation| operation.call(self) }
    transaction.define_singleton_method(:zadd) { |*values| writes << values }
    transaction.define_singleton_method(:zremrangebyscore) { |*| nil }
    transaction.define_singleton_method(:expire) { |*| nil }
    Sidekiq.define_singleton_method(:redis) { |&operation| operation.call(transaction) }
    job = { "jid" => "internal-job-id", "class" => "Worker", "wrapped" => "ApplicationJob",
      "args" => ["private input"], "error_message" => "private details", "retry_count" => 0 }
    BackgroundJobHistory.record(job, "default", task: nil, error: ArgumentError.new("secret text"))
    payload = writes.sole.last
    metadata = JSON.parse(payload)
    assert_equal "ApplicationJob", metadata["worker"]
    assert_equal "ArgumentError", metadata["error_class"]
    assert_equal 2, metadata["number"]
    assert_no_match(/secret text|private input|private details|internal-job-id/, payload)
  ensure
    Sidekiq.define_singleton_method(:redis, original_redis)
  end

  private

  def attempt(at, job_key, task, error_class, number: 1)
    { at: at.to_f, job_key: job_key, task: task, worker: "Worker", queue: "default", error_class: error_class, number: number }.to_json
  end
end

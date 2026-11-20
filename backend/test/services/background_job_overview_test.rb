require "test_helper"

class BackgroundJobOverviewTest < ActiveSupport::TestCase
  setup do
    @original_write = BackgroundJobOverview.method(:write_result)
    @writes = []
    writes = @writes
    BackgroundJobOverview.define_singleton_method(:write_result) { |name, json| writes << [ name, JSON.parse(json) ] }
  end
  teardown { BackgroundJobOverview.define_singleton_method(:write_result, @original_write) }

  def run_job(klass = "Notifications::DeliveryWorker", &block)
    BackgroundJobOverview::CronResultRecorder.new.call(nil, { "class" => klass, "args" => [] }, "default", &block)
  end

  test "configured workers record completion success and failure without changing job behavior or retaining secrets" do
    assert_equal :done, run_job { :done }
    error = Net::ReadTimeout.new("access_token=patient-secret")
    assert_same error, assert_raises(Net::ReadTimeout) { run_job { raise error } }
    assert_equal [ "notification_delivery", "notification_delivery" ], @writes.map(&:first)
    assert_equal [ true, false ], @writes.map { |_, result| result["succeeded"] }
    assert_equal "Net::ReadTimeout", @writes.last.last["error_class"]
    assert_not_includes @writes.to_json, "patient-secret"
    assert @writes.last.last["finished_at"]
    assert_equal :other, run_job("OtherWorker") { :other }
    assert_equal 2, @writes.size
  end

  test "result recording failures cannot turn a successful job into a failed job or replace its exception" do
    BackgroundJobOverview.define_singleton_method(:write_result) { |*| raise RedisClient::CannotConnectError, "private Redis URL" }
    assert_equal :done, run_job { :done }
    error = ArgumentError.new("private")
    assert_same error, assert_raises(ArgumentError) { run_job { raise error } }
  end

  test "schedule discoveries include future notification workers and disambiguate shared worker classes" do
    original = BackgroundJobOverview.method(:schedule)
    config = { "new_notice" => { "class" => "NewNoticeWorker", "cron" => "* * * * *", "queue" => "notice", "args" => [ 1 ] } }
    BackgroundJobOverview.define_singleton_method(:schedule) { config }
    assert_includes BackgroundJobOverview.configured_queues, "notice"
    assert_equal "new_notice", BackgroundJobOverview.cron_name_for({ "class" => "NewNoticeWorker", "args" => [ 1 ] }, "notice")
    assert_nil BackgroundJobOverview.cron_name_for({ "class" => "NewNoticeWorker", "args" => [ 2 ] }, "notice")
    config["same_worker"] = config["new_notice"].merge("args" => [ 2 ])
    assert_equal "same_worker", BackgroundJobOverview.cron_name_for({ "class" => "NewNoticeWorker", "args" => [ 2 ] }, "notice")
  ensure
    BackgroundJobOverview.define_singleton_method(:schedule, original)
  end

  test "failure projection omits args messages and backtraces including wrapped jobs" do
    job = Sidekiq::JobRecord.new({ "class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "ActiveStorage::AnalyzeJob", "queue" => "default",
      "args" => [ { "secret" => "patient-name" } ], "error_message" => "access_token=secret", "error_backtrace" => [ "private" ],
      "error_class" => "Net::ReadTimeout", "retry_count" => 2, "failed_at" => Time.current.to_f, "retried_at" => (Time.current + 60).to_f })
    result = BackgroundJobOverview.recent_failures([ job ], "retry").sole
    assert_equal "ActiveStorage::AnalyzeJob", result.job_class
    assert_equal 2, result.retry_count
    assert_equal "Net::ReadTimeout", result.error_class
    assert_no_match(/patient-name|access_token|private/, result.inspect)
    [ nil, "[]", "null", "{", '{"finished_at":"bad","succeeded":false}' ].each do |raw|
      assert_equal({}, BackgroundJobOverview.parse_result(raw))
    end
  end
end

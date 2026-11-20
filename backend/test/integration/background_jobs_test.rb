require "test_helper"

class BackgroundJobsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup { @original_fetch = BackgroundJobOverview.method(:fetch) }
  teardown { BackgroundJobOverview.define_singleton_method(:fetch, @original_fetch) }

  def snapshot(empty: false)
    now = Time.current
    BackgroundJobOverview::Overview.new(queues: [ BackgroundJobOverview::QueueCount.new(name: "default", waiting: empty ? 0 : 12, busy: empty ? 0 : 2) ],
      scheduled: 0, retries: empty ? 0 : 3, dead: empty ? 0 : 1, captured_at: now,
      processes: empty ? [] : [ BackgroundJobOverview::ProcessInfo.new(hostname: "worker-1", pid: 123, busy: 2, concurrency: 3, queues: [ "default" ], quiet: false, heartbeat_at: now) ],
      cron_jobs: [ BackgroundJobOverview::CronJob.new(name: "notification_delivery", label: "通知投递检查", cron: "* * * * *", queue: "default",
        enqueued_at: now, finished_at: empty ? nil : now - 60, succeeded: empty ? nil : false, error_class: empty ? nil : "Net::ReadTimeout") ],
      failures: empty ? [] : [ BackgroundJobOverview::Failure.new(job_class: "Notifications::DeliveryWorker", queue: "default", state: "retry", failed_at: now, retry_count: 2, error_class: "Net::ReadTimeout") ])
  end

  test "snapshot distinguishes queued from completed and shows processes queues and safe failure details read only" do
    data = snapshot
    BackgroundJobOverview.define_singleton_method(:fetch) { data }
    sign_in Admin.create!(username: "job_super", role: "super_admin")
    get admins_background_jobs_path
    assert_response :success
    assert_select "[data-job-queue='default']", text: /等待 12 · 执行 2/
    assert_select "[data-job-cron='notification_delivery']", text: /上次|失败/
    assert_includes response.body, "最近入队尚无完成记录"
    assert_includes response.body, "worker-1"
    assert_includes response.body, "Net::ReadTimeout"
    assert_select "main form, main button", count: 0
  end

  test "empty queues missing process heartbeat and no execution records each have their own state" do
    data = snapshot(empty: true)
    BackgroundJobOverview.define_singleton_method(:fetch) { data }
    sign_in Admin.create!(username: "job_empty", role: "super_admin")
    get admins_background_jobs_path
    assert_response :success
    [ "队列为空", "暂无工作进程心跳", "暂无执行记录", "当前没有等待重试或最终失败的任务" ].each { |text| assert_includes response.body, text }
  end

  test "Redis outages are unavailable and cannot be mistaken for an empty healthy queue" do
    BackgroundJobOverview.define_singleton_method(:fetch) { raise RedisClient::CannotConnectError, "redis://private-secret" }
    sign_in Admin.create!(username: "job_unavailable", role: "super_admin")
    get admins_background_jobs_path
    assert_response :success
    assert_select "[data-jobs-unavailable]", count: 1
    assert_select "[data-job-queue]", count: 0
    assert_not_includes response.body, "private-secret"
  end

  test "unauthenticated and other roles cannot access monitor or see menu and no mutations are routed" do
    get admins_background_jobs_path
    assert_redirected_to new_admin_session_path
    %w[operator customer_service].each do |role|
      sign_in Admin.create!(username: "job_#{role}", role: role)
      get admins_root_path
      assert_select "a[href=?]", admins_background_jobs_path, count: 0
      get admins_background_jobs_path
      assert_response :forbidden
    end
    %w[POST PATCH DELETE].each do |verb|
      assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path(admins_background_jobs_path, method: verb) }
    end
  end
end

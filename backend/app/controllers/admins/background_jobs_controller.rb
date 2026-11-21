module Admins
  class BackgroundJobsController < BaseController
    before_action :require_super_admin!

    def show
      @overview = BackgroundJobOverview.fetch
      @history = BackgroundJobHistory.fetch(@overview.captured_at, task_names: @overview.cron_jobs.map(&:name))
    rescue RedisClient::Error, Redis::BaseError, ConnectionPool::TimeoutError
      @unavailable = @overview.nil?
    end
  end
end

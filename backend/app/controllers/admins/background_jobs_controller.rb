module Admins
  class BackgroundJobsController < BaseController
    before_action :require_super_admin!

    def show
      @overview = BackgroundJobOverview.fetch
    rescue RedisClient::Error, Redis::BaseError, ConnectionPool::TimeoutError
      @unavailable = true
    end
  end
end

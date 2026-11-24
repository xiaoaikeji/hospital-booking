# frozen_string_literal: true

require "sidekiq/api"

# Loopback-only deployment verification endpoint confirming booted Booking release, DB readability, and Sidekiq heartbeats.
class DeployChecksController < ActionController::API
  LOOPBACK_ADDRS = %w[127.0.0.1 ::1].freeze

  def show
    return head :not_found unless loopback_direct_request?

    response.headers["Cache-Control"] = "no-store"
    db_ok = database_readable?
    sidekiq_ok, processes = read_sidekiq_processes
    status = db_ok && sidekiq_ok ? :ok : :service_unavailable

    render json: {
      app: DeployIdentity.app_name,
      release: DeployIdentity.release,
      revision: DeployIdentity.revision,
      pid: Process.pid,
      checked_at: Time.now.to_f,
      database: db_ok ? "ok" : "error",
      sidekiq: {
        ok: sidekiq_ok,
        expected_tag: DeployIdentity.sidekiq_tag,
        processes:
      }
    }, status:
  end

  private

  def loopback_direct_request?
    LOOPBACK_ADDRS.include?(request.remote_addr.to_s) &&
      request.env["HTTP_X_FORWARDED_FOR"].blank? &&
      request.env["HTTP_X_REAL_IP"].blank?
  end

  def database_readable?
    ActiveRecord::Base.connection_pool.with_connection do |conn|
      conn.select_value("SELECT 1").to_i == 1 && conn.table_exists?("schema_migrations")
    end
  rescue StandardError
    false
  end

  def read_sidekiq_processes
    processes = Sidekiq::ProcessSet.new(false).map do |process|
      {
        pid: process["pid"].to_i,
        tag: process.tag.to_s,
        hostname: process["hostname"].to_s,
        started_at: process["started_at"].to_f,
        beat: process["beat"].to_f,
        stopping: process.stopping?,
        queues: Array(process.queues).map(&:to_s)
      }
    end
    [ true, processes ]
  rescue StandardError
    [ false, [] ]
  end
end

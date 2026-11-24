# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../../../lib/capistrano/deploy_verifier"

class BookingCapistranoDeployVerifierTest < Minitest::Test
  def test_passes_when_up_and_booking_release_db_and_fresh_sidekiq_match
    result = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload.to_json,
      expected_release: "20261124100001",
      expected_revision: "abc1234",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )

    assert result.ok?
    assert_nil result.reason
    assert_includes result.summary, "app=booking"
    assert_includes result.summary, "release=20261124100001"
    assert_includes result.summary, "sidekiq_pid=4321"
  end

  def test_rejects_other_app_answering_200_on_up
    result = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "404",
      deploy_body: "Not Found",
      expected_release: "20261124100001"
    )

    refute result.ok?
    assert_includes result.reason, "/up/deploy 返回 404"

    wrong_app = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(app: "other-project").to_json,
      expected_release: "20261124100001"
    )

    refute wrong_app.ok?
    assert_includes wrong_app.reason, "预期 booking"
  end

  def test_rejects_old_booking_release_or_revision
    old_release = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(release: "20261124090000").to_json,
      expected_release: "20261124100001"
    )

    refute old_release.ok?
    assert_includes old_release.reason, "20261124090000"

    old_revision = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(revision: "0000000").to_json,
      expected_release: "20261124100001",
      expected_revision: "abc1234"
    )

    refute old_revision.ok?
    assert_includes old_revision.reason, "0000000"
  end

  def test_rejects_unreadable_database
    result = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "503",
      deploy_body: valid_payload(database: "error").to_json,
      expected_release: "20261124100001"
    )

    refute result.ok?
    assert_includes result.reason, "503"

    body_error = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(database: "error").to_json,
      expected_release: "20261124100001"
    )

    refute body_error.ok?
    assert_includes body_error.reason, "数据库读取检查失败"
  end

  def test_rejects_stale_or_wrong_sidekiq_worker_heartbeat
    stale_tag = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(process: { pid: 1000, tag: "booking:20261124090000", started_at: 1_795_485_605, beat: 1_795_485_606, stopping: false, queues: %w[default] }).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute stale_tag.ok?

    stale_pid = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(process: { pid: 1000, tag: "booking:20261124100001", started_at: 1_795_485_605, beat: 1_795_485_606, stopping: false, queues: %w[default] }).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute stale_pid.ok?

    stale_started_at = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(process: { pid: 4321, tag: "booking:20261124100001", started_at: 1_795_485_500, beat: 1_795_485_606, stopping: false, queues: %w[default] }).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute stale_started_at.ok?

    stopping_worker = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(process: { pid: 4321, tag: "booking:20261124100001", started_at: 1_795_485_605, beat: 1_795_485_606, stopping: true, queues: %w[default] }).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute stopping_worker.ok?

    missing_queue = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(process: { pid: 4321, tag: "booking:20261124100001", started_at: 1_795_485_605, beat: 1_795_485_606, stopping: false, queues: %w[mailers] }).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute missing_queue.ok?
  end

  def test_rejects_exited_sidekiq_or_restarted_pid_until_new_worker_emits_fresh_beat
    exited_unit = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload.to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      jobs_service_active: false,
      restarted_at: 1_795_485_600
    )
    refute exited_unit.ok?
    assert_includes exited_unit.reason, "active"

    zero_pid = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload.to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 0,
      jobs_service_active: true,
      restarted_at: 1_795_485_600
    )
    refute zero_pid.ok?
    assert_includes zero_pid.reason, "MainPID=0"

    round_one_old_pid_lingering = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(process: { pid: 4321, tag: "booking:20261124100001", started_at: 1_795_485_602, beat: 1_795_485_604, stopping: false, queues: %w[default] }).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4500,
      jobs_service_active: true,
      restarted_at: 1_795_485_600
    )
    refute round_one_old_pid_lingering.ok?
    assert_includes round_one_old_pid_lingering.reason, "pid=4500"

    round_two_restarted_fresh_pid = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(
        checked_at: 1_795_485_612.0,
        process: { pid: 4500, tag: "booking:20261124100001", started_at: 1_795_485_608, beat: 1_795_485_610, stopping: false, queues: %w[default] }
      ).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4500,
      jobs_service_active: true,
      restarted_at: 1_795_485_600
    )
    assert round_two_restarted_fresh_pid.ok?
    assert_includes round_two_restarted_fresh_pid.summary, "sidekiq_pid=4500"

    pre_restart_beat = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(
        checked_at: 1_795_485_605.0,
        process: { pid: 4321, tag: "booking:20261124100001", started_at: 1_795_485_598.5, beat: 1_795_485_599.0, stopping: false, queues: %w[default] }
      ).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute pre_restart_beat.ok?

    stale_beat = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(
        checked_at: 1_795_485_630.0,
        process: { pid: 4321, tag: "booking:20261124100001", started_at: 1_795_485_602.5, beat: 1_795_485_603.0, stopping: false, queues: %w[default] }
      ).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute stale_beat.ok?

    missing_checked_at = BookingCapistrano::DeployVerifier.verify(
      up_http_code: "200",
      deploy_http_code: "200",
      deploy_body: valid_payload(checked_at: nil).to_json,
      expected_release: "20261124100001",
      expected_jobs_pid: 4321,
      restarted_at: 1_795_485_600
    )
    refute missing_checked_at.ok?
    assert_includes missing_checked_at.reason, "checked_at"
  end

  def test_builds_deploy_check_url_and_parses_curl_output
    assert_equal "http://127.0.0.1:3000/up/deploy", BookingCapistrano::DeployVerifier.deploy_check_url("http://127.0.0.1:3000/up")
    assert_equal [ "{\"ok\":true}", "200" ], BookingCapistrano::DeployVerifier.parse_curl_output("{\"ok\":true}\n200\n")
    assert_equal [ "", "000" ], BookingCapistrano::DeployVerifier.parse_curl_output("\n000")
  end

  private

  def valid_payload(app: "booking", release: "20261124100001", revision: "abc1234", database: "ok", checked_at: 1_795_485_605.0, process: nil)
    proc_entry = process || {
      pid: 4321,
      tag: "booking:20261124100001",
      hostname: "app-01",
      started_at: 1_795_485_602.5,
      beat: 1_795_485_603.0,
      stopping: false,
      queues: %w[default]
    }
    payload = {
      app:,
      release:,
      revision:,
      pid: 1234,
      database:,
      sidekiq: {
        ok: true,
        expected_tag: "booking:20261124100001",
        processes: [ proc_entry ]
      }
    }
    payload[:checked_at] = checked_at unless checked_at.nil?
    payload
  end
end

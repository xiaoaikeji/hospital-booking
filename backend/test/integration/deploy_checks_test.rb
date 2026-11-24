# frozen_string_literal: true

require "test_helper"
require "sidekiq/api"

class DeployChecksTest < ActionDispatch::IntegrationTest
  test "up stays 200 and direct loopback /up/deploy reports booking identity and db health" do
    get "/up"
    assert_response :success

    fake_set = []
    with_process_set(->(_clean = true) { fake_set }) do
      get "/up/deploy", env: { "REMOTE_ADDR" => "127.0.0.1" }
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "booking", body["app"]
    assert_equal DeployIdentity.release, body["release"]
    assert_kind_of Numeric, body["checked_at"]
    assert_operator body["checked_at"], :>, 0
    assert_equal "ok", body["database"]
    assert_equal true, body.dig("sidekiq", "ok")
    assert_equal "booking:#{DeployIdentity.release}", body.dig("sidekiq", "expected_tag")
    assert_equal [], body.dig("sidekiq", "processes")
  end

  test "rejects forwarded or non-loopback requests to /up/deploy with 404" do
    get "/up/deploy", headers: { "X-Forwarded-For" => "203.0.113.10" }, env: { "REMOTE_ADDR" => "127.0.0.1" }
    assert_response :not_found

    get "/up/deploy", headers: { "X-Real-IP" => "203.0.113.10" }, env: { "REMOTE_ADDR" => "127.0.0.1" }
    assert_response :not_found

    get "/up/deploy", env: { "REMOTE_ADDR" => "203.0.113.10" }
    assert_response :not_found
  end

  test "returns 503 without leaking redis connection details when sidekiq redis is unavailable" do
    with_process_set(->(_clean = true) { raise RedisClient::CannotConnectError, "redis://secret-host:6379/0" }) do
      get "/up/deploy", env: { "REMOTE_ADDR" => "127.0.0.1" }
    end

    assert_response :service_unavailable
    body = response.parsed_body
    assert_equal "booking", body["app"]
    assert_equal "ok", body["database"]
    assert_equal false, body.dig("sidekiq", "ok")
    assert_not_includes response.body, "secret-host"
  end

  private

  def with_process_set(impl)
    original_new = Sidekiq::ProcessSet.method(:new)
    Sidekiq::ProcessSet.define_singleton_method(:new, &impl)
    yield
  ensure
    Sidekiq::ProcessSet.define_singleton_method(:new, original_new)
  end
end

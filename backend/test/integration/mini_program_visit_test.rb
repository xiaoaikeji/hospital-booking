require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class MiniProgramVisitTest < ActionDispatch::IntegrationTest
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @mini_app = App.create!(provider: "wechat", appid: "fixture_visit", appsecret: SecureRandom.hex, status: "active")
    @stubs.get("/sns/jscode2session") { response_for(openid: "fixture-without-union") }
    @lookups = []
    @region = { status: 0, address: "CN|广东省|深圳市|None", content: { address_detail: { province: "广东省", city: "深圳市" } } }
    @stubs.get("/location/ip") do |env|
      assert_equal "api.map.baidu.com", env.url.host
      @lookups << env.params.fetch("ip")
      assert_equal @key, env.params.fetch("ak")
      raise Faraday::TimeoutError if @timeout
      response_for(@region)
    end
  end
  teardown { remove_wechat_stubs }

  test "a scan stores both source values and a later authorized visit fills only missing real-device and public IP fields" do
    login({ launch_scene: 1047, channel_scene: "门诊大厅", device_platform: "devtools", device_model: "iPhone", operating_system: "iOS" })
    binding = UserApp.for_app(@mini_app).sole
    assert_nil binding.unionid
    assert_empty binding.user.login_profile
    entry = { "launch_scene" => 1047, "channel_scene" => "门诊大厅" }
    assert_equal entry, binding.first_entry
    assert_equal entry, Log.where(action: "mini_program.entry", target_id: binding.id).sole.details
    visit({ device_platform: "ios", device_model: "unknown", operating_system: "iOS 17" }, peer: "127.0.0.1", forwarded: "1.1.1.1")
    visit({ launch_scene: 1007, device_platform: "android", device_model: "Fixture phone", operating_system: "Android 14" },
      peer: "8.8.8.8", forwarded: "9.9.9.9")
    assert_equal({ "device_model" => "Fixture phone", "operating_system" => "iOS 17", "first_ip" => "1.1.1.1" }, binding.user.reload.login_profile)
    assert_equal entry, binding.reload.first_entry
    assert_equal 2, Log.where(action: "mini_program.entry", target_id: binding.id).count
    login({})
    assert_equal 2, Log.where(action: "mini_program.entry", target_id: binding.id).count
    assert_equal "Fixture phone", profile.fetch("device_model")
    refute profile.key?("first_ip")
  end

  test "private, reserved and forwarded addresses from untrusted peers cannot become the first public IP" do
    %w[127.0.0.1 10.2.3.4 100.64.0.1 192.0.2.18 ::1 fc00::1 fe80::2 2001:db8::1 1.1.1.0/24].each do |address|
      assert_nil IpLocation.public_address(address)
    end
    login({}, peer: "8.8.8.8", forwarded: "1.1.1.1")
    assert_equal "8.8.8.8", UserApp.for_app(@mini_app).sole.user.login_profile["first_ip"]
  end

  test "missing key, timeouts and quotas leave the session usable and a later configured key backfills the outstanding region once" do
    login({}, peer: "8.8.8.8")
    user = UserApp.for_app(@mini_app).sole.user
    Sidekiq.testing!(:fake) do
      assert_no_difference -> { UserIpLocationWorker.jobs.size } do
        UserIpLocationWorker.new.perform
      end
      assert_nil profile["region"]
      assert_empty @lookups
      row = Setting.create!(key: "baidu_map")
      @key = SecureRandom.hex
      row.write_value("ak", @key)
      row.save!
      @timeout = true
      assert_raises(HttpConnection::Unavailable) { UserIpLocationWorker.new.perform(user.id) }
      assert_nil profile["region"]
      @timeout = false
      successful_region = @region
      @region = { status: 302 }
      assert_raises(HttpConnection::Unavailable) { UserIpLocationWorker.new.perform(user.id) }
      assert_nil profile["region"]
      @region = successful_region
      @key = SecureRandom.hex
      row.write_value("ak", @key)
      row.save!
      assert_difference -> { UserIpLocationWorker.jobs.size }, 1 do
        2.times { UserIpLocationWorker.new.perform }
      end
      assert_equal [ user.id ], UserIpLocationWorker.jobs.last.fetch("args")
      UserIpLocationWorker.drain
      assert_equal({ "country" => "CN", "province" => "广东省", "city" => "深圳市" }, profile.fetch("region"))
      UserIpLocationWorker.new.perform(user.id)
      UserIpLocationWorker.new.perform
      assert_empty UserIpLocationWorker.jobs
      assert_equal Array.new(3, "8.8.8.8"), @lookups
    end
  end

  test "a failed location enqueue leaves the user eligible and the login, binding and profile endpoints available" do
    settings = Setting.create!(key: "baidu_map")
    settings.write_value("ak", SecureRandom.hex)
    settings.save!
    @stubs.post("/cgi-bin/stable_token") { response_for(access_token: SecureRandom.hex, expires_in: 7200) }
    @stubs.post("/wxa/business/getuserphonenumber") do
      response_for(phone_info: { purePhoneNumber: "10000000001", countryCode: 86, watermark: { appid: @mini_app.appid } })
    end
    disconnected_worker = Class.new(UserIpLocationWorker) do
      def self.perform_bulk(*) = raise(RedisClient::CannotConnectError)
    end

    Sidekiq.testing!(:fake) do
      assert_no_difference -> { UserIpLocationWorker.jobs.size } do
        login({}, peer: "8.8.8.8")
        assert_raises(RedisClient::CannotConnectError) { disconnected_worker.new.perform }
        login({})
        post api_mini_program_phone_binding_path(@mini_app.appid), headers: { "Authorization" => "Bearer #{@token}" },
          params: { code: SecureRandom.hex }, as: :json
        assert_response :success
        assert_equal "10000000001", profile.fetch("mobile")
        assert_nil profile["region"]
        assert_empty @lookups
      end
      assert_difference -> { UserIpLocationWorker.jobs.size }, 1 do
        UserIpLocationWorker.new.perform
      end
    ensure
      UserIpLocationWorker.clear
    end
  end

  private

  def login(context, peer: "127.0.0.1", forwarded: nil)
    post api_mini_program_session_path(@mini_app.appid), headers: { "REMOTE_ADDR" => peer, "HTTP_X_FORWARDED_FOR" => forwarded },
      params: context.merge(code: SecureRandom.hex), as: :json
    assert_response :created
    @token = response.parsed_body.fetch("token")
  end

  def visit(context, peer:, forwarded:)
    post api_mini_program_entry_scenes_path(@mini_app.appid),
      headers: { "REMOTE_ADDR" => peer, "HTTP_X_FORWARDED_FOR" => forwarded, "Authorization" => "Bearer #{@token}" },
      params: context, as: :json
    assert_response :no_content
  end

  def profile
    get api_mini_program_me_path(@mini_app.appid), headers: { "Authorization" => "Bearer #{@token}" }
    assert_response :success
    response.parsed_body
  end
end

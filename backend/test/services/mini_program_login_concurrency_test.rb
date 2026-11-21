require "test_helper"
require_relative "../support/wechat_http_test"

class MiniProgramLoginConcurrencyTest < ActiveSupport::TestCase
  include WechatHttpTest
  self.use_transactional_tests = false

  setup do
    install_wechat_stubs
    @apps = 2.times.map { App.create!(provider: "wechat", appid: "test_#{SecureRandom.hex(8)}", status: "active", appsecret: SecureRandom.hex) }
    @stubs.get("/sns/jscode2session") do |env|
      response_for(openid: "fixture-#{env.params.fetch('appid')}", unionid: @unionid)
    end
  end

  teardown do
    remove_wechat_stubs
    @setting&.destroy!
    ids = UserApp.where(appid: @apps.map(&:appid)).pluck(:user_id)
    UserApp.where(appid: @apps.map(&:appid)).delete_all
    User.where(id: ids).delete_all
    @apps.each(&:destroy!)
  end

  test "simultaneous first login, cleanup, issue and revoke keep exactly the surviving devices" do
    app = @apps.first
    tokens = together(*Array.new(3) { -> { login(app) } })
    binding = UserApp.for_app(app).sole
    assert_equal 3, binding.sign_in_count
    assert_equal 3, tokens.uniq.size
    stale_digest = Digest::SHA256.hexdigest(tokens.last)
    binding.update!(sessions: binding.sessions.merge(stale_digest => 1.day.ago.to_i))

    fresh, = together(-> { login(app) }, -> { MiniProgramSession.new(app, tokens.first).revoke! },
      -> { MiniProgramSession.prune_expired! })
    expected = [ tokens.second, fresh ].map { |token| Digest::SHA256.hexdigest(token) }
    assert_equal expected.sort, binding.reload.sessions.keys.sort
  end

  test "simultaneous new bindings from two confirmed apps converge on one platform user" do
    @setting = Setting.create!(key: "wechat", settings: { unionid_app_groups: [ @apps.map(&:appid) ] })
    @unionid = "fixture-#{SecureRandom.hex}"
    together(*@apps.map { |app| -> { login(app) } })
    assert_equal 1, UserApp.where(appid: @apps.map(&:appid)).distinct.count(:user_id)
    @apps.each { |app| assert_equal 1, UserApp.for_app(app).sole.sessions.size }
  end

  private

  def login(app)
    MiniProgramLogin.new(App.find(app.id)).call(SecureRandom.hex).fetch(:token)
  end

  def together(*actions)
    ready, start = Queue.new, Queue.new
    threads = actions.map do |action|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          action.call
        end
      end
    end
    threads.size.times { ready.pop }
    threads.size.times { start << true }
    threads.map(&:value)
  end
end

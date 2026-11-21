require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationTemplateOccurrencesTest < ActionDispatch::IntegrationTest
  include WechatHttpTest
  include Devise::Test::IntegrationHelpers

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "notice_template_confirmation", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxDemoVenueA wxDemoVenueB].map do |appid|
      account = App.create!(provider: "wechat", app_type: "official_account", appid: appid)
      configure_account(account)
      account
    end
    @catalog_reads = []
    @calls = []
    @stubs.get("/cgi-bin/template/get_all_private_template") do |env|
      account = env.params.fetch("access_token")
      @catalog_reads << account
      response_for(template_list: [ { template_id: "tpl_#{account}", title: "活动提醒",
        content: "活动名称：{{thing1.DATA}}\n开始时间：{{time2.DATA}}" } ])
    end
    @stubs.post("/cgi-bin/message/template/send") do |env|
      @calls << [ env.params.fetch("access_token"), JSON.parse(env.body) ]
      response_for(errcode: 0, msgid: @calls.size)
    end
  end
  teardown { remove_wechat_stubs }

  def fan(account, openid)
    identity = UserApp.create!(app: account, user: User.create!(platform: "wechat"), openid: openid)
    identity.create_official_account_fan!(subscribed: true, observed_at: Time.current)
    identity
  end

  test "一次绑定供两个活动复用，收件人按公众号独立，同一事件改展示名不重复发送" do
    Sidekiq.testing!(:fake) do
      get admins_template_messages_path(app_id: @a.id)
      assert_response :success
      assert_includes response.body, "tpl_#{@a.appid}"
      assert_not_includes response.body, "tpl_#{@b.appid}"
      config = Notifications::AccountConfiguration.new(@a)
      patch admins_app_template_message_path(@a), as: :json, params: { template_binding: {
        event: "activity_start", template_id: "tpl_#{@a.appid}", revision: config.revision,
        mapping: { thing1: "activity_name", time2: "starts_at" }
      } }
      assert_response :success
      confirmed_reads = @catalog_reads.dup
      alice = fan(@a, "alice")
      bob = fan(@a, "bob")
      fan(@b, "alice")
      sender = Notifications::TemplateMessages.new(@a)
      %w[场馆开放日 下周联赛].each_with_index do |name, i|
        starts_at = Time.zone.local(2026, 11, 21 + 7 * i, 14, 30)
        # Each activity has its own registration code in the host project.
        registration = OfficialAccountQrcode.create!(app: @a, name: name, scene: format("qd_%012d", i + 1),
          ticket: "local-activity-#{i}", url: "https://example.test/activities/#{i}")
        input = { event: "activity_start", subject: registration, recipients: [ alice, bob, alice ],
          data: { activity_name: registration.name, starts_at: starts_at }, idempotency_key: "start-reminder",
          jump: { url: "https://example.test/activities/#{i}" } }
        rows = sender.deliver(**input)
        assert_equal 2, rows.length
        assert rows.all? { |row| row.subject == registration }
        rows.each { |r| Notifications::DeliveryWorker.new.perform(r.id) }
        @a.update!(nickname: "场馆新名称")
        assert_equal rows.map(&:id), sender.deliver(**input).map(&:id)
      end
      assert_equal confirmed_reads, @catalog_reads
      assert_equal [ @a.appid ] * 4, @calls.map(&:first)
      assert_equal %w[alice bob alice bob], @calls.map { |_, m| m.fetch("touser") }
      assert_equal %w[场馆开放日 场馆开放日 下周联赛 下周联赛], @calls.map { |_, m| m.dig("data", "thing1", "value") }
      assert_equal 2, @calls.map { |_, m| m.dig("data", "time2", "value") }.uniq.size
      assert_equal 4, Notification.where(status: "sent").count
      assert_equal 1, Log.where(action: "notification.template_bind", status: "success").count
    end
  end
end

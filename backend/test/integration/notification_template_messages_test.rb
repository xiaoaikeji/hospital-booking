require "test_helper"
require "sidekiq/testing"
require_relative "../support/wechat_http_test"

class NotificationTemplateMessagesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include WechatHttpTest

  setup do
    install_wechat_stubs
    @admin = Admin.create!(username: "template_admin", role: "super_admin")
    sign_in @admin
    @a, @b = %w[wxTemplateA wxTemplateB].map do |appid|
      App.create!(provider: "wechat", app_type: "official_account", appid: appid).tap do |account|
        configure_account(account)
      end
    end
    @recipient = UserApp.create!(app: @a, user: User.create!(platform: "wechat"), openid: "fan-a")
    @recipient.create_official_account_fan!(subscribed: true, observed_at: Time.current)
    @config = Notifications::AccountConfiguration.new(@a)
    @reads = 0
    @sent = []
    @stubs.get("/cgi-bin/template/get_all_private_template") do |env|
      @reads += 1
      if @template_error
        response_for(errcode: 48001)
      else
        response_for(template_list: [ { template_id: "tpl-#{env.params['access_token']}", title: "活动开始提醒", content: "活动名称：{{thing1.DATA}}\n开始时间：{{time2.DATA}}" } ])
      end
    end
    @stubs.post("/cgi-bin/message/template/send") do |env|
      @sent << [ env.params["access_token"], JSON.parse(env.body) ]
      response_for(errcode: 0, msgid: @sent.size)
    end
  end
  teardown { remove_wechat_stubs }

  test "即使微信模板不可读，解除当前事件也保留其他事件和账号的绑定" do
    Notifications::EventCatalog.register("activity_reminder", label: "另一活动", fields: {
      "activity_name" => { label: "活动名称", type: "text" }, "starts_at" => { label: "开始时间", type: "time" }
    })
    [@a, @b].each do |app|
      config = Notifications::AccountConfiguration.new(app)
      %w[activity_start activity_reminder].each do |event|
        patch admins_app_template_message_path(app), params: { template_binding: { event: event,
          template_id: "tpl-#{app.appid}", revision: config.revision, mapping: { thing1: "activity_name", time2: "starts_at" } } }, as: :json
        assert_response :success
      end
    end
    @template_error = true
    get admins_template_messages_path(app_id: @a.id)
    assert_response :success
    assert_select "[data-template-event='activity_start'] [data-template-unbind]:not(.d-none)"
    assert_select "[data-template-event='activity_start'] [data-template-choice]", count: 0
    revision = css_select("#unbind-template-activity_start input[name='template_binding[revision]']").sole["value"]
    delete admins_app_template_message_path(@a), params: { template_binding: { event: "activity_start", revision: revision } }
    assert_redirected_to admins_template_messages_path(app_id: @a.id)
    assert_equal ["activity_reminder"], @config.data.fetch("template_bindings").keys
    assert_includes Notifications::AccountConfiguration.new(@b).data.fetch("template_bindings"), "activity_start"
    assert Log.exists?(action: "notification.template_unbind", target_id: @a.id, status: "success")
  ensure
    Notifications::EventCatalog.definitions.delete("activity_reminder")
  end

  test "读出微信字段并建议配置一次，两次活动复用相同绑定和真实数据" do
    get admins_template_messages_path(app_id: @a.id)
    assert_response :success
    assert_includes response.body, "活动开始提醒"
    assert_equal({ "thing1" => "活动名称", "time2" => "开始时间" }, Notifications::TemplateMessages.fields("活动名称：{{thing1.DATA}}\n开始时间：{{time2.DATA}}"))
    assert_equal "activity_name", Notifications::TemplateMessages.guess("activity_start", "thing1", "活动名称")
    assert_equal "starts_at", Notifications::TemplateMessages.guess("activity_start", "time2", "开始时间")
    patch admins_app_template_message_path(@a), params: { template_binding: { event: "activity_start", template_id: "tpl-wxTemplateA", revision: @config.revision, mapping: { thing1: "activity_name", time2: "starts_at" } } }, as: :json
    assert_response :success
    reads = @reads
    service = Notifications::TemplateMessages.new(@a)
    2.times do |index|
      task = service.deliver(event: "activity_start", subject: @a, recipients: [ @recipient ],
        data: { activity_name: "第#{index + 1}场活动", starts_at: Time.zone.local(2026, 11, 28 + index, 14) },
        idempotency_key: "activity:#{index}", jump: { url: "https://example.com/activities/#{index}" }).sole
      2.times { Notifications::Delivery.run(task.id) }
      assert_equal "sent", task.reload.status
    end
    assert_equal reads, @reads
    assert_equal [ "第1场活动", "第2场活动" ], @sent.map { |_, body| body.dig("data", "thing1", "value") }
    assert_equal [ "2026年11月28日 14:00", "2026年11月29日 14:00" ], @sent.map { |_, body| body.dig("data", "time2", "value") }
    assert_equal [ "wxTemplateA" ], @sent.map(&:first).uniq
    assert_equal 1, Log.where(action: "notification.template_bind", status: "success").count
    assert_empty Notifications::AccountConfiguration.new(@b).data
  end

  test "同机构 B 模板、粉丝身份不能用于 A；计划发送由业务提供" do
    service = Notifications::TemplateMessages.new(@a)
    assert_raises(Notifications::Error) { service.bind!(event: "activity_start", template_id: "tpl-wxTemplateB", mapping: {}, revision: @config.revision, actor: @admin) }
    service.bind!(event: "activity_start", template_id: "tpl-wxTemplateA", mapping: { thing1: "activity_name", time2: "starts_at" }, revision: @config.revision, actor: @admin)
    other = UserApp.create!(app: @b, user: User.create!(platform: "wechat"), openid: "fan-b")
    other.create_official_account_fan!(subscribed: true, observed_at: Time.current)
    input = { event: "activity_start", subject: @a, data: { activity_name: "周末活动", starts_at: Time.current }, idempotency_key: "next", scheduled_at: 1.hour.from_now }
    assert_raises(ActiveRecord::RecordNotFound) { service.deliver(**input, recipients: [ other ]) }
    row = service.deliver(**input, recipients: [ @recipient ]).sole
    Notifications::Delivery.run(row.id)
    assert_empty @sent
    sign_in Admin.create!(username: "template_support", role: "customer_service")
    get admins_template_messages_path(app_id: @a.id)
    assert_response :forbidden
    patch admins_app_template_message_path(@a), params: { template_binding: {} }
    assert_response :forbidden
  end
end

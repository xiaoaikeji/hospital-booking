require "test_helper"

class OperationLogsTest < ActionDispatch::IntegrationTest
  test "operators and customer service see their own actions and only root sees both" do
    operator, support, root = %w[operator customer_service super_admin].map do |role|
      Admin.create!(username: role, role: role)
    end
    personal_logs = [ operator, support ].index_with do |admin|
      login(admin)
      patch admins_personal_appearance_path, params: { revision: AppearanceSettings.new(admin: admin).revision,
        appearance: { theme_primary: "purple" } }, as: :json
      assert_response :success
      Log.find_by!(action: "personal_appearance.update", actor_id: admin.id)
    end
    login(root)
    patch admins_administrator_path(operator), params: { administrator: { name: "运营" } }
    assert_redirected_to admins_administrators_path
    targeted = Log.find_by!(action: "admin.update", actor_id: root.id, target_id: operator.id)

    callback = Log.record!(source: "webhook", category: "payment", action: "payment.notify", actor: operator)
    unlisted = Log.record!(category: "security", action: "internal.check", actor: support)
    background = Log.record!(source: "job", category: "security", action: "storage_settings.refresh", actor: operator)
    other_category = Log.record!(category: "payment", action: "admin.update", actor: support)
    failed_login = Log.record!(category: "security", action: "admin.sign_in", status: "failed")
    other_actor_type = Log.create!(source: "admin", category: "security", action: "admin.sign_in", status: "success",
      actor_type: "User", actor_id: operator.id)

    [ operator, support, root ].each do |admin|
      login(admin)
      hidden = [ callback, unlisted, background, other_category ]
      if admin.super_admin?
        visible = personal_logs.values + [ targeted, failed_login, other_actor_type ]
      else
        visible = [ personal_logs.fetch(admin) ]
        hidden += personal_logs.except(admin).values + [ targeted, failed_login, other_actor_type ]
      end

      assert_no_difference "Log.count" do
        get admins_operation_logs_path
        assert_response :success
        assert_select "#sidebar-menu a[href=?]", admins_operation_logs_path
        assert_select "select[name=actor_id]", count: admin.super_admin? ? 1 : 0
        visible.each { |log| assert_select "tbody td", text: "##{log.id}" }
        hidden.each { |log| assert_select "tbody td", text: "##{log.id}", count: 0 }

        get admins_operation_logs_path, params: { operation: "personal_appearance.update",
          status: "success", actor_id: admin == operator ? support.id : operator.id }
        expected = admin.super_admin? ? operator : admin
        assert_select "tbody tr", count: 1
        assert_select "tbody td", text: "##{personal_logs.fetch(expected).id}"
        get admins_operation_logs_path, params: { operation: callback.action }
        assert_select "tbody tr", count: 0

        visible.each do |log|
          get admins_operation_log_path(log)
          assert_response :success
        end
        hidden.each do |log|
          get admins_operation_log_path(log)
          assert_response :not_found
        end
      end
    end
  end

  test "each execution status has the same label in the filter, list and detail" do
    admin = Admin.create!(username: "op", role: "operator")
    login(admin)
    labels = { "started" => "已开始", "success" => "成功", "failed" => "失败", "skipped" => "已跳过" }
    records = labels.keys.index_with do |status|
      Log.record!(category: "security", action: "admin.password", actor: admin, status: status)
    end
    labels.each do |status, label|
      filters = { operation: "admin.password", status: status }
      path = admins_operation_logs_path(filters)
      get path
      assert_response :success
      assert_select "nav[aria-label=结果] a[aria-current=page][href=?]", path, text: label
      assert_select "tbody tr", count: 1
      assert_select "tbody .badge", text: label
      detail_path = admins_operation_log_path(records.fetch(status), filters)
      assert_select "tbody a[href=?]", detail_path
      get detail_path
      assert_response :success
      assert_select ".datagrid .badge", text: label
    end
  end

  test "date and result filters and pagination preserve the authorized list" do
    admin = Admin.create!(username: "op", role: "operator")
    other = Admin.create!(username: "cs", role: "customer_service")
    record = ->(actor, status) { Log.record!(category: "security", action: "admin.password", actor: actor, status: status) }
    day = Date.new(2026, 11, 18)
    travel_to(day.in_time_zone) do
      @first = record.call(admin, "failed")
      19.times { record.call(admin, "failed") }
    end
    travel_to(day.tomorrow.in_time_zone.end_of_day) do
      @last = record.call(admin, "failed")
      record.call(admin, "success")
      record.call(other, "failed")
    end
    travel_to((day + 2).in_time_zone) { record.call(admin, "failed") }
    travel_to(day.yesterday.in_time_zone.end_of_day) { record.call(admin, "failed") }

    login(admin)
    filters = { date_range: "#{day} – #{day.tomorrow}", status: "failed", operation: "admin.password" }
    assert_no_difference "Log.count" do
      get admins_operation_logs_path, params: filters
      assert_response :success
      assert_select "input[name=date_range][data-bs-selection-mode=multiple-ranged][value=?]", filters[:date_range]
      assert_select "tbody tr", count: 20
      assert_select "tbody tr:first-child td", text: "##{@last.id}"
      get css_select("nav[aria-label=列表分页] a").find { |link| link.text == "下一页" }["href"]
      assert_select "tbody tr", count: 1
      assert_select "tbody a[href=?]", admins_operation_log_path(@first, filters.merge(page: 2))
      get css_select("tbody a").first["href"]
      assert_select "a[href=?]", admins_operation_logs_path(filters.merge(page: 2)), text: /返回列表/
    end
  end

  test "component preview filters its sample log by the selected dates" do
    login(Admin.create!(username: "preview", role: "operator"))
    day = Date.current
    preview = { tab: "list_examples", example: "logs" }
    get admins_components_path, params: preview.merge(date_range: "#{day.yesterday} – #{day}")
    assert_response :success
    assert_select "input[name=date_range][data-bs-selection-mode=multiple-ranged]"
    assert_select "tbody td", text: "示例管理员"

    get admins_components_path, params: preview.merge(date_range: day.tomorrow.iso8601)
    assert_response :success
    assert_select "tbody tr", count: 0
    assert_select "a[href=?]", admins_components_path(preview), text: "重置筛选"
  end

  private

  def login(admin)
    reset!
    post admin_session_path, params: { admin: { username: admin.username, password: "123456" } }
    assert_redirected_to admins_root_path
  end
end

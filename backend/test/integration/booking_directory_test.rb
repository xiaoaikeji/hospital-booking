require "test_helper"

class BookingDirectoryTest < ActionDispatch::IntegrationTest
  setup do
    @admin = Admin.create!(username: "booking_directory_admin", role: "super_admin")
    post admin_session_path, params: { admin: { username: @admin.username, password: Admin::DEFAULT_PASSWORD } }
    assert_redirected_to admins_root_path
    @mini_program = App.create!(provider: "wechat", app_type: "mini_program", appid: "directory-test", status: "active")
  end

  test "a new department can be selected along with another department and the doctor keeps a single fee" do
    get new_admins_department_path
    assert_response :success
    assert_select "input[name='department[position][]']", count: 0
    post admins_departments_path, params: { department: { name: "耳鼻喉科" } }
    assert_redirected_to admins_departments_path
    follow_redirect!
    assert_response :success
    assert_select "td", text: /耳鼻喉科/

    department = Department.find_by!(name: "耳鼻喉科")
    other = Department.create!(name: "五官门诊")
    get new_admins_doctor_path
    assert_response :success
    assert_select "select[name='doctor[department_ids][]'] option[value=?]", department.id.to_s, text: "耳鼻喉科"
    post admins_doctors_path, params: { doctor: { name: "张医生", main_title: "主治医师", good_in: "耳鼻喉常见病",
      introduction: "门诊医生", fee: "20.00", department_ids: [ "", department.id.to_s, other.id.to_s ],
      image: fixture_file_upload("storage.png", "image/png") } }
    assert_redirected_to admins_doctors_path
    follow_redirect!
    assert_response :success
    assert_select "td", text: /20 元/
    doctor = Doctor.find_by!(name: "张医生")
    assert_select "th", text: "医生姓名" do |headers|
      assert_equal "职称", headers.sole.next_element.text
    end
    assert_select "#doctor_#{doctor.id} td.directory-title", text: "主治医师"
    assert_select "#doctor_#{doctor.id} a[href=?]", admins_doctor_path(doctor), count: 2
    assert_select "#doctor_#{doctor.id} .directory-action-cell a[href=?]", admins_doctor_path(doctor), text: /查看/
    assert_equal [ department.id, other.id ].sort, doctor.department_ids.sort
    assert_equal 1, Doctor.current.enabled.count
    assert_equal "20", doctor.fee_in_yuan
    assert doctor.image.attached?
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_response :success
    directory = response.parsed_body.fetch("directory")
    assert_includes directory.fetch("departments").pluck("id"), department.id.to_s
    published = directory.fetch("doctors").sole
    assert_equal [ "张医生", "20", true ], published.values_at("name", "fee", "display_on_homepage")
    assert_equal [ department.id.to_s, other.id.to_s ].sort, published.fetch("department_ids").sort
    image_path = URI(published.fetch("image_url")).path
    get image_path
    assert_response :success
    assert_equal "image/png", response.media_type
    get edit_admins_doctor_path(doctor)
    assert_response :success

    patch admins_doctor_path(doctor), params: { doctor: { fee: "21.235", department_ids: [ other.id.to_s ] } }
    assert_response :unprocessable_content
    assert_select "#fee-error", text: "挂号费最多保留两位小数"
    assert_select "select[name='doctor[department_ids][]'] option[selected]", count: 1 do |options|
      assert_equal other.id.to_s, options.first["value"]
    end
    assert_equal [ department.id, other.id ].sort, doctor.reload.department_ids.sort
    assert_equal "20", doctor.fee_in_yuan
    assert_equal 0, Log.where(action: "doctor.change_fee", target_id: doctor.id, status: "success").count

    patch admins_doctor_path(doctor), params: { doctor: { fee: "21.50", sort_order: 3 } }
    assert_redirected_to admins_doctors_path
    price = Log.find_by!(action: "doctor.change_fee", target_id: doctor.id, status: "success")
    assert_equal @admin.id, price.actor_id
    assert_equal({ "fields" => [ "fee" ], "fee" => "21.5" }, price.details)
    assert_equal "21.5", doctor.reload.fee_in_yuan
    assert_equal({ "fields" => [ "sort_order" ], "sort_order" => 3 },
      Log.find_by!(action: "doctor.reorder", target_id: doctor.id).details)
    get admins_operation_log_path(price)
    assert_response :success
    assert_select "dd", text: "21.5"
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_equal "21.5", response.parsed_body.dig("directory", "doctors", 0, "fee")

    patch status_admins_doctor_path(doctor), params: { status: 0 }
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_empty response.parsed_body.dig("directory", "doctors")
    get image_path
    assert_response :not_found
  end

  test "directory changes need working storage only when uploading an image" do
    Setting.create!(key: "active_storage", settings: { "service" => "invalid" })
    post admins_departments_path, params: { department: { name: "耳鼻喉科" } }
    assert_redirected_to admins_departments_path
    department = Department.find_by!(name: "耳鼻喉科")
    doctor = Doctor.create!(name: "张医生", fee: 20, departments: [ department ])

    patch admins_doctor_path(doctor), params: { doctor: { fee: "25" } }
    assert_redirected_to admins_doctors_path
    assert_equal "25", doctor.reload.fee_in_yuan

    patch status_admins_department_path(department), params: { status: 0 }
    assert_redirected_to admins_departments_path
    assert_not department.reload.enabled?

    patch admins_department_path(department), params: { department: { image: fixture_file_upload("storage.png", "image/png") } }
    assert_response :service_unavailable
    assert_not department.reload.image.attached?
    assert_equal [ "failed" ], Log.where(action: "department.update", target_id: department.id).pluck(:status)
  end

  test "the sixth doctor cannot be enabled until an existing doctor has been stopped" do
    department = Department.create!(name: "耳鼻喉科")
    doctors = Doctor::ENABLED_LIMIT.times.map { |i| Doctor.create!(name: "医师 #{i + 1}", departments: [ department ]) }
    assert_no_difference -> { Doctor.count } do
      post admins_doctors_path, params: { doctor: { name: "第六位", department_ids: [ department.id ] } }
      assert_response :unprocessable_content
      assert_select "#status-error", text: /最多同时启用 5 位/
    end
    post admins_doctors_path, params: { doctor: { name: "第六位", status: 0, department_ids: [ department.id ] } }
    assert_redirected_to admins_doctors_path
    sixth = Doctor.find_by!(name: "第六位")
    patch status_admins_doctor_path(sixth), params: { status: 1 }
    assert_redirected_to admins_doctors_path
    assert_not sixth.reload.enabled?
    assert_equal [ "failed" ], Log.where(action: "doctor.enable", target_id: sixth.id).pluck(:status)

    patch status_admins_doctor_path(doctors.first), params: { status: 0 }
    assert_not doctors.first.reload.enabled?
    patch status_admins_doctor_path(sixth), params: { status: 1 }
    assert sixth.reload.enabled?
    assert_equal 5, Doctor.current.enabled.count
    assert_equal({ "fields" => [ "status" ], "status_value" => 1 },
      Log.find_by!(action: "doctor.enable", target_id: sixth.id, status: "success").details)
  end

  test "a department cannot be moved into its own subtree" do
    top = Department.create!(name: "五官科")
    child = Department.create!(name: "耳鼻喉科", parent: top)
    patch admins_department_path(top), params: { department: { parent_id: child.id } }
    assert_response :unprocessable_content
    assert_select "#parent_id-error", text: /不能是自身或其下级科室/
    assert_nil top.reload.parent_id
    assert_equal [ "failed" ], Log.where(action: "department.update", target_id: top.id).pluck(:status)
  end

  test "a department uses its uploaded image or the current name initial" do
    department = Department.create!(name: "全科门诊", icon: "旧")
    config_path = api_app_configuration_path(@mini_program.provider, @mini_program.appid)

    get edit_admins_department_path(department)
    assert_response :success
    assert_select "input[name='department[icon]']", count: 0
    assert_select "input[type='file'][name='department[image]']"

    get config_path
    assert_equal [ "全", nil ], response.parsed_body.dig("directory", "departments").sole.values_at("icon", "image_url")

    patch admins_department_path(department), params: { department: { name: "眼科", image: fixture_file_upload("storage.png", "image/png") } }
    assert_redirected_to admins_departments_path
    edit = Log.find_by!(action: "department.update", target_id: department.id, status: "success")
    assert_equal %w[image name], edit.details.fetch("fields").sort
    get config_path
    published = response.parsed_body.dig("directory", "departments").sole
    assert_nil published.fetch("icon")
    get URI(published.fetch("image_url")).path
    assert_response :success

    patch admins_department_path(department), params: { department: { remove_image: "1" } }
    assert_redirected_to admins_departments_path
    get config_path
    assert_equal [ "眼", nil ], response.parsed_body.dig("directory", "departments").sole.values_at("icon", "image_url")
  end

  test "department visibility follows the status of each department and its ancestors" do
    root = Department.create!(name: "门诊部", sort_order: 10, position: [])
    parent = Department.create!(name: "五官科", parent: root)
    child = Department.create!(name: "耳鼻喉科", parent: parent, sort_order: 3, position: [ "index" ])
    sibling = Department.create!(name: "口腔科", parent: parent, sort_order: 4)
    other = Department.create!(name: "眼科", sort_order: 1, icon: "眼")
    doctor = Doctor.create!(name: "张医生", departments: [ child, other ], display_on_homepage: false)
    config_path = api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    patch admins_department_path(child), params: { department: { image: fixture_file_upload("storage.png", "image/png") } }
    assert_redirected_to admins_departments_path

    get config_path
    directory = response.parsed_body.fetch("directory")
    departments = directory.fetch("departments")
    assert_equal [ other.id, root.id, parent.id, child.id, sibling.id ].map(&:to_s), departments.pluck("id")
    assert_equal [ 0, 0, 1, 2, 2 ], departments.pluck("depth")
    assert_equal "眼", directory.dig("departments", 0, "icon")
    assert_not directory.dig("doctors", 0, "display_on_homepage")
    image_path = URI(departments.find { |entry| entry["id"] == child.id.to_s }.fetch("image_url")).path
    get image_path
    assert_response :success

    patch status_admins_department_path(sibling), params: { status: 0 }
    assert_redirected_to admins_departments_path
    get config_path
    assert_equal [ other.id, root.id, parent.id, child.id ].map(&:to_s), response.parsed_body.dig("directory", "departments").pluck("id")

    patch status_admins_department_path(root), params: { status: 0 }
    assert_redirected_to admins_departments_path
    assert child.reload.enabled?
    assert_includes doctor.reload.department_ids, child.id
    get config_path
    assert_equal [ other.id.to_s ], response.parsed_body.dig("directory", "departments").pluck("id")
    assert_equal [ other.id.to_s ], response.parsed_body.dig("directory", "doctors", 0, "department_ids")
    get image_path
    assert_response :not_found

    patch status_admins_department_path(root), params: { status: 1 }
    get config_path
    assert_equal [ other.id, root.id, parent.id, child.id ].map(&:to_s), response.parsed_body.dig("directory", "departments").pluck("id")
    assert_not sibling.reload.enabled?
    get image_path
    assert_response :success
  end

  test "doctor searches order matching decimal fees before pagination and keep hospital order for ties" do
    department = Department.create!(name: "儿科")
    other = Department.create!(name: "眼科")
    hidden = Department.create!(name: "门诊部", status: 0)
    hidden_child = Department.create!(name: "儿保", parent: hidden)
    high = Doctor.create!(name: "张甲", fee: 35, sort_order: 1, departments: [ department ])
    middle = Doctor.create!(name: "张乙", fee: "18.5", sort_order: 3, departments: [ department ])
    earlier = Doctor.create!(name: "张丙", fee: "18.5", sort_order: 2, departments: [ department ])
    free = Doctor.create!(name: "张丁", fee: 0, sort_order: 40, departments: [ department, other, hidden_child ])
    Doctor.create!(name: "张戊", fee: 0, departments: [ other ])
    Doctor.create!(name: "张己", fee: 0, status: 0, departments: [ department ])
    # An imported directory can span a page even though new records must obey the enabled limit.
    imported = Doctor.insert_all!(Array.new(18) { |i| { name: "张医师#{i}", fee: 35, sort_order: 4 } }).rows.flatten
    DoctorDepartment.insert_all!(imported.map { |id| { doctor_id: id, department_id: department.id } })
    api_path = api_mini_program_doctors_path(@mini_program.appid)
    query = { q: " 张 ", department_id: department.id }

    get api_path, params: query
    assert_response :success
    assert_equal [ high.id, earlier.id, middle.id ], response.parsed_body.fetch("doctors").first(3).pluck("id").map(&:to_i)
    get api_path, params: query.merge(sort: "fee_asc")
    result = response.parsed_body
    assert_equal [ free.id, earlier.id, middle.id, high.id, *imported.first(16) ].map(&:to_s), result.fetch("doctors").pluck("id")
    assert_equal [ "0", "18.5", "18.5", "35" ], result.fetch("doctors").first(4).pluck("fee")
    assert_equal [ department.id, other.id ].map(&:to_s).sort, result.fetch("doctors").first.fetch("department_ids").sort
    get api_path, params: query.merge(sort: "fee_desc", page: result.fetch("next_page"))
    assert_equal [ middle.id, free.id ].map(&:to_s), response.parsed_body.fetch("doctors").pluck("id")
    assert_nil response.parsed_body.fetch("next_page")
    get api_path, params: query.merge(department_id: hidden_child.id)
    assert_empty response.parsed_body.fetch("doctors")

    get admins_doctors_path, params: query.merge(sort: "fee_asc", status: 1, display_on_homepage: 1)
    assert_select "th[aria-sort=ascending] form[action=?]", admins_doctors_path do
      assert_select "button[name=sort][value=fee_desc]"
      assert_select "input[name=q][value=?]", "张"
      assert_select "input[name=department_id][value=?]", department.id.to_s
      assert_select "input[name=status][value='1']"
      assert_select "input[name=display_on_homepage][value='1']"
    end
    assert_select "tbody > tr" do |rows|
      assert_equal [ free.id, earlier.id, middle.id, high.id ].map { |id| "doctor_#{id}" }, rows.first(4).map { |row| row["id"] }
    end
  end

  test "homepage recommendation uses the stored preference and removing a doctor archives their department links and schedule" do
    departments = %w[儿科 眼科].map { |name| Department.create!(name:) }
    doctor = Doctor.create!(name: "张医师", departments:, recommend: true)
    date = Date.current
    shift = doctor.schedules.create!(start_date: date, end_date: date, weekday: date.wday, time_slot: "AM", capacity: 20)
    api_path = api_mini_program_doctors_path(@mini_program.appid)
    config_path = api_app_configuration_path(@mini_program.provider, @mini_program.appid)

    get edit_admins_doctor_path(doctor)
    assert_select "label", text: "首页推荐" do
      assert_select "input[name='doctor[display_on_homepage]'][checked]"
    end
    patch admins_doctor_path(doctor), params: { doctor: { display_on_homepage: "0", recommend: "0" } }
    assert_redirected_to admins_doctors_path
    assert doctor.reload.recommend?
    update = Log.find_by!(action: "doctor.update", target_id: doctor.id)
    assert_equal({ "fields" => [ "display_on_homepage" ], "display_on_homepage" => false }, update.details)
    get config_path
    assert_equal false, response.parsed_body.dig("directory", "doctors", 0, "display_on_homepage")
    assert_equal "AM", response.parsed_body.dig("schedule", 0, "doctors", doctor.id.to_s, 0)
    departments.each do |department|
      get api_path, params: { department_id: department.id }
      assert_equal [ doctor.id.to_s ], response.parsed_body.fetch("doctors").pluck("id")
    end

    delete admins_doctor_path(doctor)
    assert_redirected_to admins_doctors_path
    assert doctor.reload.deleted_at?
    assert_equal departments.map(&:id).sort, doctor.department_ids.sort
    assert_equal [ shift.id ], doctor.schedules.ids
    removal = Log.find_by!(action: "doctor.destroy", target_id: doctor.id, status: "success")
    assert_equal @admin.id, removal.actor_id
    get admins_operation_log_path(removal)
    assert_response :success
    get admins_doctors_path
    assert_select "#doctor_#{doctor.id}", count: 0
    get admins_doctor_path(doctor)
    assert_response :not_found
    get admins_doctor_schedule_path(doctor)
    assert_response :not_found
    get config_path
    assert_empty response.parsed_body.dig("directory", "doctors")
    assert_empty response.parsed_body.dig("schedule", 0, "doctors")
    get api_path, params: { q: "张", department_id: departments.first.id }
    assert_empty response.parsed_body.fetch("doctors")
    @mini_program.update!(status: "disabled")
    get api_path
    assert_response :forbidden
    assert_equal "disabled", response.parsed_body.fetch("status")
  end

  test "operators can maintain the directory while customer service can only view it" do
    operator = Admin.create!(username: "directory_operator", role: "operator")
    staff = Admin.create!(username: "directory_support", role: "customer_service")
    open_session do |browser|
      browser.post admin_session_path, params: { admin: { username: operator.username, password: Admin::DEFAULT_PASSWORD } }
      browser.post admins_departments_path, params: { department: { name: "运营创建" } }
      assert_equal 303, browser.response.status
      department = Department.find_by!(name: "运营创建")
      browser.post admins_doctors_path, params: { doctor: { name: "运营医生", fee: "20", department_ids: [ department.id ] } }
      assert_equal 303, browser.response.status
      doctor = Doctor.find_by!(name: "运营医生")
      browser.get admins_doctors_path
      assert_select browser.html_document, "#doctor_#{doctor.id} td.directory-title", text: "—"
      assert_select browser.html_document, "#doctor_#{doctor.id} a[href=?]", admins_doctor_path(doctor), count: 2
      assert_select browser.html_document, "a[href=?]", edit_admins_doctor_path(doctor)
    end
    department = Department.find_by!(name: "运营创建")
    doctor = Doctor.find_by!(name: "运营医生")
    open_session do |browser|
      browser.post admin_session_path, params: { admin: { username: staff.username, password: Admin::DEFAULT_PASSWORD } }
      browser.get admins_doctors_path, params: { q: "运营", sort: "fee_asc", display_on_homepage: 1 }
      assert_equal 200, browser.response.status
      assert_select browser.html_document, "th[aria-sort=ascending]"
      assert_select browser.html_document, "#sidebar-menu a[href=?]", admins_departments_path
      assert_select browser.html_document, "a[href=?]", new_admins_doctor_path, count: 0
      assert_select browser.html_document, "a[href=?]", admins_doctor_path(doctor), text: /查看/
      assert_select browser.html_document, "a[href=?]", edit_admins_doctor_path(doctor), count: 0
      assert_select browser.html_document, "#doctor_#{doctor.id} .directory-action-cell button", count: 0
      browser.get admins_doctor_path(doctor)
      assert_equal 200, browser.response.status
      assert_select browser.html_document, "dd", text: "20 元"
      browser.patch admins_doctor_path(doctor), params: { doctor: { fee: "1", display_on_homepage: "0" } }
      assert_equal 403, browser.response.status
      browser.delete admins_doctor_path(doctor)
      assert_equal 403, browser.response.status
      browser.patch status_admins_doctor_path(doctor), params: { status: 0 }
      assert_equal 403, browser.response.status
      browser.patch status_admins_department_path(department), params: { status: 0 }
      assert_equal 403, browser.response.status
    end
    assert department.reload.enabled?
    assert_equal "20", doctor.reload.fee_in_yuan
    assert doctor.display_on_homepage?
    assert_nil doctor.deleted_at
  end
end

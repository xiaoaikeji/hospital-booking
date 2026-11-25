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
    post admins_departments_path, params: { department: { name: "耳鼻喉科", position: [ "", "department" ] } }
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

  test "a disabled parent hides its subtree without changing the children's status" do
    parent = Department.create!(name: "五官科", sort_order: 10)
    city = Department.create!(name: "耳鼻喉科", parent: parent, sort_order: 3)
    other = Department.create!(name: "眼科", sort_order: 1, icon: "眼")
    Department.create!(name: "仅首页科室", position: [ "index" ])
    doctor = Doctor.create!(name: "张医生", departments: [ city, other ], display_on_homepage: false)

    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    directory = response.parsed_body.fetch("directory")
    assert_equal [ other.id.to_s, parent.id.to_s, city.id.to_s ], directory.fetch("departments").pluck("id")
    assert_equal [ 0, 0, 1 ], directory.fetch("departments").pluck("depth")
    assert_equal "眼", directory.dig("departments", 0, "icon")
    assert_not directory.dig("doctors", 0, "display_on_homepage")

    patch status_admins_department_path(parent), params: { status: 0 }
    assert_redirected_to admins_departments_path
    assert city.reload.enabled?
    assert_includes doctor.reload.department_ids, city.id
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_equal [ other.id.to_s ], response.parsed_body.dig("directory", "departments").pluck("id")
    assert_equal [ other.id.to_s ], response.parsed_body.dig("directory", "doctors", 0, "department_ids")

    patch status_admins_department_path(parent), params: { status: 1 }
    get api_app_configuration_path(@mini_program.provider, @mini_program.appid)
    assert_includes response.parsed_body.dig("directory", "departments").pluck("id"), city.id.to_s
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
    end
    department = Department.find_by!(name: "运营创建")
    doctor = Doctor.find_by!(name: "运营医生")
    open_session do |browser|
      browser.post admin_session_path, params: { admin: { username: staff.username, password: Admin::DEFAULT_PASSWORD } }
      browser.get admins_doctors_path
      assert_equal 200, browser.response.status
      assert_select browser.html_document, "#sidebar-menu a[href=?]", admins_departments_path
      assert_select browser.html_document, "a[href=?]", new_admins_doctor_path, count: 0
      assert_select browser.html_document, "a[href=?]", admins_doctor_path(doctor), text: /查看/
      browser.get admins_doctor_path(doctor)
      assert_equal 200, browser.response.status
      assert_select browser.html_document, "dd", text: "20 元"
      browser.patch admins_doctor_path(doctor), params: { doctor: { fee: "1" } }
      assert_equal 403, browser.response.status
      browser.patch status_admins_department_path(department), params: { status: 0 }
      assert_equal 403, browser.response.status
    end
    assert department.reload.enabled?
    assert_equal "20", doctor.reload.fee_in_yuan
  end
end

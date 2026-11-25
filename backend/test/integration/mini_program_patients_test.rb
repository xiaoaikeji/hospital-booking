require "test_helper"

class MiniProgramPatientsTest < ActionDispatch::IntegrationTest
  setup do
    @mini_program = App.create!(provider: "wechat", appid: "clinic_patients_test", status: "active")
    @alice = User.create!(platform: "wechat")
    @bob = User.create!(platform: "wechat")
    @alice_headers = session_headers(@alice, "fixture-a")
    @bob_headers = session_headers(@bob, "fixture-b")
    @first, @second = [ 24, 63 ].map { |age| @alice.patients.create!(name: "虚构同名", gender: 2, age: age) }
    @other = @bob.patients.create!(name: "虚构同名", gender: 1, age: 30)
    @list = Rails.application.routes.url_helpers.api_mini_program_patients_path(@mini_program.appid)
  end

  test "a session can only list, read, edit and remove records belonging to its user" do
    get @list
    assert_response :unauthorized

    get @list, params: { user_id: @bob.id }, headers: @alice_headers
    assert_response :ok
    assert_equal [ @first.id.to_s, @second.id.to_s ], response.parsed_body.fetch("patients").pluck("id")
    get @list, headers: @bob_headers
    assert_response :ok
    assert_equal [ @other.id.to_s ], response.parsed_body.fetch("patients").pluck("id")

    get patient_path(@first), headers: @bob_headers
    assert_response :not_found
    patch patient_path(@first), headers: @bob_headers, as: :json, params: { patient: { age: 200 } }
    assert_response :not_found
    delete patient_path(@first), headers: @bob_headers
    assert_response :not_found
    assert_equal 24, @first.reload.age
  end

  test "updates affect only the identified profile and removal preserves the other same-name record" do
    get patient_path(@second), headers: @alice_headers
    assert_response :ok
    assert_equal({ "id" => @second.id.to_s, "name" => "虚构同名", "gender" => 2, "age" => 63 }, response.parsed_body)

    assert_difference -> { profile_logs.count }, 1 do
      patch patient_path(@second), headers: @alice_headers, as: :json, params: {
        patient: { name: " 虚构改名 ", gender: 1, age: 200, phone: "10000000003", user_id: @bob.id }
      }
      assert_response :ok
    end
    assert_equal({ "id" => @second.id.to_s, "name" => "虚构改名", "gender" => 1, "age" => 200 }, response.parsed_body)
    assert_nil @second.reload.phone
    assert_equal @alice.id, @second.user_id
    assert_equal({ "fields" => %w[name gender age] }, profile_logs.last.details)
    assert_equal @alice.id, profile_logs.last.actor_id

    assert_difference -> { profile_logs.count }, 1 do
      delete patient_path(@second), headers: @alice_headers
      assert_response :no_content
    end
    assert_equal "patient.remove", profile_logs.last.action
    assert_equal @second.id, profile_logs.last.target_id
    get @list, headers: @alice_headers
    assert_equal [ @first.id.to_s ], response.parsed_body.fetch("patients").pluck("id")
  end

  test "invalid profile data is rejected and the failure audit contains only a reason code" do
    patch patient_path(@first), headers: @alice_headers, as: :json, params: {
      patient: { name: "虚构失败名称", age: 201, phone: "10000000004", symptoms: "虚构症状" }
    }
    assert_response :unprocessable_content
    assert_equal "invalid_patient", response.parsed_body.fetch("code")
    assert_equal "虚构同名", @first.reload.name
    assert_equal "failed", profile_logs.sole.status
    assert_equal({ "reason" => "invalid_profile" }, profile_logs.sole.details)
  end

  private

  def patient_path(patient) = Rails.application.routes.url_helpers.api_mini_program_patient_path(@mini_program.appid, patient.id)

  def session_headers(user, openid)
    identity = user.user_apps.create!(provider: "wechat", appid: @mini_program.appid, openid: openid)
    { "Authorization" => "Bearer #{MiniProgramSession.issue!(identity).fetch(:token)}" }
  end

  def profile_logs = Log.where(source: "user", category: "booking", target_type: "Patient").order(:id)
end

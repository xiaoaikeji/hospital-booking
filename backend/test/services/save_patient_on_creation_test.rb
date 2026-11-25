require "test_helper"

class SavePatientOnCreationTest < ActiveSupport::TestCase
  # Stand in for the future appointment row with a real write on the same database connection.
  class AppointmentResult
    def initialize(row)
      @row = row
    end

    def persisted? = @row.persisted?
    def user_id = @row.settings.fetch("user_id")
    def patient_id = @row.settings["patient_id"]
    def patient_name = @row.settings.fetch("patient_name")
    def patient_gender = @row.settings.fetch("patient_gender")
    def patient_age = @row.settings.fetch("patient_age")

    def update!(patient_id:)
      @row.update!(settings: @row.settings.merge("patient_id" => patient_id))
    end
  end

  setup { @user = User.create!(platform: "wechat") }

  test "an opted-in successful creation saves and links the snapshot only once" do
    booking = nil
    assert_difference -> { @user.patients.count }, 1 do
      booking = save_patient(true) { [ create_booking, true ] }
    end
    patient = @user.patients.find(booking.patient_id)
    assert_equal [ "虚构就诊人", 2, 63, nil ], [ patient.name, patient.gender, patient.age, patient.phone ]
    assert_equal({ "fields" => %w[name gender age] }, Log.find_by!(action: "patient.create", target_type: "Patient", target_id: patient.id).details)

    assert_no_difference -> { @user.patients.count } do
      assert_equal booking, save_patient(true) { [ booking, false ] }
    end
  end

  test "a successful creation without consent stays unlinked" do
    assert_no_difference -> { @user.patients.count } do
      booking = save_patient(false) { [ create_booking, true ] }
      assert_nil booking.patient_id
    end
    assert Setting.exists?(key: "booking_creation_fixture")
  end

  test "rejected creation and failed writes roll back the booking and the profile" do
    assert_no_difference -> { @user.patients.count } do
      assert_nil save_patient(true) {
        create_booking
        nil
      }
      assert_raises ActiveRecord::RecordInvalid do
        save_patient(true) { [ create_booking(age: 201), true ] }
      end
    end
    refute Setting.exists?(key: "booking_creation_fixture")
  end

  private

  def save_patient(consent, &block)
    Appointments::SavePatientOnCreation.call(user: @user, save_patient: consent, &block)
  end

  def create_booking(age: 63)
    AppointmentResult.new(Setting.create!(key: "booking_creation_fixture", settings: {
      user_id: @user.id, patient_name: "虚构就诊人", patient_gender: 2, patient_age: age, patient_mobile: "10000000001"
    }))
  end
end

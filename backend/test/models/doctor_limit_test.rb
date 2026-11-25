require "test_helper"

class DoctorLimitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @department = Department.create!(name: "并发验收科室")
    @doctors = (Doctor::ENABLED_LIMIT - 1).times.map { |i| Doctor.create!(name: "医师 #{i}", departments: [ @department ]) }
    @candidates = 2.times.map { |i| Doctor.create!(name: "待启用 #{i}", status: 0, departments: [ @department ]) }
  end

  teardown do
    doctor_ids = (@doctors + @candidates).map(&:id)
    DoctorDepartment.where(doctor_id: doctor_ids).delete_all
    Doctor.where(id: doctor_ids).delete_all
    @department.destroy!
  end

  test "only one concurrent request can claim the last enabled slot" do
    ready, start = Queue.new, Queue.new
    attempts = @candidates.map do |doctor|
      Thread.new do
        Doctor.connection_pool.with_connection do
          candidate = Doctor.find(doctor.id)
          ready << true
          start.pop
          candidate.update(status: 1)
        end
      end
    end
    attempts.size.times { ready.pop }
    attempts.size.times { start << true }
    assert_equal 1, attempts.count { |attempt| attempt.value }
    assert_equal Doctor::ENABLED_LIMIT, Doctor.current.enabled.count
  end
end

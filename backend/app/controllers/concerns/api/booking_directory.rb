module Api
  module BookingDirectory
    private

    def booking_departments = @booking_departments ||= Department.booking_rows
    def booking_department_ids = @booking_department_ids ||= booking_departments.map { |department, _| department.id.to_s }.to_set
    def booking_doctor_scope = Doctor.current.enabled.includes(:doctor_departments).with_attached_image

    def serialize_booking_doctors(doctors)
      doctors.map do |doctor|
        department_ids = doctor.doctor_departments.map { |link| link.department_id.to_s }.select { |id| booking_department_ids.include?(id) }
        doctor.slice(:name, :main_title, :good_in, :introduction, :display_on_homepage).merge(
          id: doctor.id.to_s, fee: doctor.fee_in_yuan, department_ids: department_ids, image_url: directory_image_url("doctors", doctor)
        )
      end
    end

    def directory_image_url(collection, entry)
      api_app_directory_image_url(@app.provider, @app.appid, collection, entry.id, entry.image.blob.key) if entry.image.attached?
    end
  end
end

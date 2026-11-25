module Admins
  class DoctorsController < DirectoryEntriesController
    ENTRY_MODEL = Doctor
    ENTRY_TITLE = "医生资料"
    ENTRY_LABEL = "医生"

    private

    def entry_scope = Doctor.current
    def list_scope = entry_scope.includes(:departments)
    def image_label = "头像"
    def upload_purpose = :doctor_portrait
    def permitted_fields = super + [ :main_title, :good_in, :introduction, :fee, :display_on_homepage, department_ids: [] ]

    def entry_details
      { "职称" => @entry.main_title, "所属科室" => @entry.departments.ordered.map(&:name).join("、"),
        "挂号费" => "#{@entry.fee_in_yuan} 元", "首页展示" => (@entry.display_on_homepage? ? "是" : "否"),
        "擅长" => @entry.good_in, "简介" => @entry.introduction }
    end

    def form_options
      @selected_department_ids = @submitted_attributes&.[](:department_ids) || @entry.department_ids
      departments = Department.ordered.to_a.index_by(&:id)
      @department_options = departments.values.map do |department|
        name = department.path_in(departments).map(&:name).join(" / ")
        name += "（已停用）" unless department.enabled?
        [ name, department.id ]
      end
    end

    def entry_attributes(attributes) = attributes.except(:department_ids)

    def assign_entry_attributes(attributes)
      fields = super
      return fields unless attributes.key?(:department_ids)

      submitted = attributes[:department_ids].compact_blank.map(&:to_s).uniq
      departments = Department.where(id: submitted).to_a
      unless departments.map { |department| department.id.to_s }.sort == submitted.sort
        @entry.errors.add(:department_ids, "请选择有效的科室")
        raise ActiveRecord::RecordInvalid.new(@entry)
      end

      if @entry.department_ids.sort != departments.map(&:id).sort
        @entry.departments = departments
        fields << "department_ids"
      end
      fields
    end

    def audit_update_fields(fields)
      super
      if fields.delete("fee")
        audit(:change_fee, fields: [ "fee" ], fee: @entry.fee_in_yuan)
      end
    end
  end
end

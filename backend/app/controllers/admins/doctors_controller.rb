module Admins
  class DoctorsController < DirectoryEntriesController
    ENTRY_MODEL = Doctor
    ENTRY_TITLE = "医生资料"
    ENTRY_LABEL = "医生"

    before_action(only: :export_schedule) { require_directory_editor! }
    before_action :load_department_options, only: :index

    def export_schedule
      filters = list_filters
      month = export_month(params[:month])
      details = { schedule_month: month&.strftime("%Y-%m"), name_filtered: filters.key?(:q),
        department_id: filters[:department_id], doctor_status: DirectoryEntry::STATUSES[filters[:status]],
        display_on_homepage: (filters[:display_on_homepage] == "1" if filters.key?(:display_on_homepage)) }.compact
      return export_failed(filters, details, ScheduleExport::INVALID_MONTH) unless month

      begin
        doctors = list_scope(filters).ordered
        file, row_count = ScheduleExport.new(doctors, month).build
      rescue StandardError => error
        Rails.logger.error { "Schedule export failed (#{error.class.name})" }
        return export_failed(filters, details, ScheduleExport::FAILURE)
      end

      audit_export(details.merge(row_count:))
      send_data file, filename: "排班-#{details[:schedule_month]}.xlsx", type: ScheduleExport::CONTENT_TYPE
    end

    private

    def entry_scope = Doctor.current
    def image_label = "头像"
    def upload_purpose = :doctor_portrait
    def permitted_fields = super + [ :main_title, :good_in, :introduction, :fee, :display_on_homepage, department_ids: [] ]

    def list_filters
      query = params[:q].strip.presence if params[:q].is_a?(String)
      department_id = params[:department_id]
      department_id = department_id.to_i if department_id.is_a?(String) && /\A[1-9][0-9]{0,18}\z/.match?(department_id)
      department_id = nil unless department_id.is_a?(Integer) && department_id.between?(1, 2**63 - 1)
      homepage = params[:display_on_homepage].presence_in(%w[0 1])
      super.merge(q: query, department_id: department_id, display_on_homepage: homepage).compact
    end

    def list_scope(filters)
      rows = super.includes(:departments)
      if (query = filters[:q])
        rows = rows.where("doctors.name ILIKE ?", "%#{Doctor.sanitize_sql_like(query)}%")
      end
      if (department_id = filters[:department_id])
        rows = rows.where(id: DoctorDepartment.where(department_id:).select(:doctor_id))
      end
      if filters.key?(:display_on_homepage)
        rows = rows.where(display_on_homepage: filters[:display_on_homepage] == "1")
      end
      rows
    end

    def export_month(value)
      return Date.current.beginning_of_month if value.nil? || value == ""
      return unless value.is_a?(String) && /\A[0-9]{4}-(?:0[1-9]|1[0-2])\z/.match?(value) && value.to_i.positive?

      Date.iso8601("#{value}-01")
    end

    def export_failed(filters, details, reason)
      audit_export(details.merge(reason:), status: "failed")
      redirect_to directory_path(**filters), alert: reason, status: :see_other
    end

    def audit_export(details, status: "success")
      Log.record!(category: "booking", action: "schedule.export", actor: current_admin, request: request, status: status, details: details)
    end

    def entry_details
      { "职称" => @entry.main_title, "所属科室" => @entry.department_names,
        "挂号费" => "#{@entry.fee_in_yuan} 元", "首页展示" => (@entry.display_on_homepage? ? "是" : "否"),
        "擅长" => @entry.good_in, "简介" => @entry.introduction }
    end

    def form_options
      @selected_department_ids = @submitted_attributes&.[](:department_ids) || @entry.department_ids
      load_department_options
    end

    def load_department_options
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

module Admins
  class DepartmentsController < DirectoryEntriesController
    ENTRY_MODEL = Department
    ENTRY_TITLE = "科室管理"
    ENTRY_LABEL = "科室"

    private

    def list_scope = entry_scope.includes(:parent)
    def permitted_fields = super + [ :parent_id, :icon, position: [] ]

    def entry_details
      { "上级科室" => @entry.parent&.name, "展示位置" => @entry.position.filter_map { |position| Department::POSITIONS[position] }.join("、"),
        "文字图标" => @entry.icon }
    end

    def form_options
      departments = Department.ordered.to_a.index_by(&:id)
      @parent_options = departments.values.filter_map do |department|
        path = department.path_in(departments)
        [ path.map(&:name).join(" / "), department.id ] unless @entry.id && path.any? { |ancestor| ancestor.id == @entry.id }
      end
    end
  end
end

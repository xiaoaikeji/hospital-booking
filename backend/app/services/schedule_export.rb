require "caxlsx"

class ScheduleExport
  CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  INVALID_MONTH = "请选择有效的导出月份"
  FAILURE = "未能导出排班，请重试"
  HEADERS = %w[日期 医生 所属科室 班次 班次号数].freeze

  def initialize(doctors, month)
    @doctors = doctors.to_a
    @dates = month.all_month
  end

  def build
    calendar = ScheduleCalendar.new(@doctors.map(&:id), @dates)
    department_names = @doctors.index_with(&:department_names)
    package = Axlsx::Package.new
    workbook = package.workbook
    header_style = workbook.styles.add_style(b: true)
    date_style = workbook.styles.add_style(format_code: "yyyy-mm-dd")
    row_count = 0

    workbook.add_worksheet(name: "排班", escape_formulas: true) do |sheet|
      sheet.add_row(HEADERS, style: header_style)
      @dates.each do |date|
        @doctors.each do |doctor|
          calendar.day_availability(doctor.id, date).fetch(:shifts).each do |shift|
            sheet.add_row([ date, doctor.name, department_names.fetch(doctor), shift.fetch(:label), shift.fetch(:total) ],
              types: [ :date, :string, :string, :string, :integer ], style: [ date_style ])
            row_count += 1
          end
        end
      end
      sheet.column_widths(14, nil, nil, 12, 12)
    end

    [ package.to_stream.string, row_count ]
  end
end

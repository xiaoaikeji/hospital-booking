module Admins
  class DoctorSchedulesController < BaseController
    WEEKLY_FIELDS = Schedule::WEEKDAYS.keys.map(&:to_s).index_with { ScheduleEditor::FIELDS }.freeze

    skip_before_action :refresh_storage_configuration
    before_action :require_directory_editor!, except: :show
    before_action :load_doctor

    def show
      tab = params[:tab] == "date" ? :date : :weekly
      if tab == :date && !params[:date].nil?
        @date = parse_date(params[:date])
        @date_error = @date.nil?
        @date_input = params[:date].is_a?(String) ? params[:date] : "" if @date_error
      end
      @date ||= Date.current
      render_schedule(tab, status: @date_error ? :unprocessable_content : :ok)
    end

    def update_weekly
      @weekly_fields = params.expect(weekly_schedule: [ WEEKLY_FIELDS ]).to_h
      if @editor.save_weekly(@weekly_fields)
        redirect_to admins_doctor_schedule_path(@doctor), notice: "每周排班已保存", status: :see_other
      else
        render_schedule(:weekly, status: :unprocessable_content)
      end
    end

    def update_date_adjustment
      @date = required_date
      @date_fields = params.expect(date_adjustment: ScheduleEditor::FIELDS).to_h
      if @editor.save_date(@date, @date_fields)
        redirect_to date_schedule_path, notice: "日期调整已保存", status: :see_other
      else
        render_schedule(:date, status: :unprocessable_content)
      end
    end

    def revoke_date_adjustment
      @date = required_date
      if @editor.revoke_date(@date)
        redirect_to date_schedule_path, notice: "日期调整已撤销", status: :see_other
      else
        render_schedule(:date, status: :unprocessable_content)
      end
    end

    private

    def load_doctor
      @doctor = Doctor.current.find(params[:doctor_id])
      @editor = ScheduleEditor.new(doctor: @doctor, actor: current_admin, request: request)
    end

    def parse_date(value)
      return unless value.is_a?(String) && /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/.match?(value)

      date = Date.iso8601(value)
      date if date.year.positive?
    rescue Date::Error
      nil
    end

    def required_date
      parse_date(params.expect(:date)) || raise(ActionController::BadRequest, "请选择有效日期")
    end

    def date_schedule_path = admins_doctor_schedule_path(@doctor, tab: "date", date: @date.iso8601)

    def render_schedule(tab, status: :ok)
      @tab = tab
      @editable = current_admin.maintain_booking_directory?
      @night_enabled = Schedule.night_enabled?
      if tab == :date
        @day = ScheduleCalendar.new([ @doctor.id ], @date..@date, night_enabled: @night_enabled).day(@doctor.id, @date)
        @date_fields ||= shift_fields(@day.shifts)
      else
        @weekly_fields ||= @doctor.schedules.weekly.active.order(:id).group_by(&:weekday).transform_keys(&:to_s).transform_values { |shifts| shift_fields(shifts) }
      end
      render :show, status: status
    end

    def shift_fields(shifts)
      day = shifts.find { |rule| Schedule::DAY_SLOTS.key?(rule.time_slot) }
      night = shifts.find(&:night?)
      { time_slot: day&.time_slot, capacity: day&.capacity, night: ("1" if night), night_capacity: night&.capacity }
    end
  end
end

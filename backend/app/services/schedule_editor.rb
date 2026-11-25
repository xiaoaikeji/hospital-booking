class ScheduleEditor
  include ActiveModel::Model

  FIELDS = %i[time_slot capacity night night_capacity].freeze
  FAILURE = "排班未保存，请重试"
  REVOKE_FAILURE = "日期调整未撤销，请重试"
  class Invalid < StandardError; end

  def initialize(doctor:, actor:, request:)
    @doctor = doctor
    @actor = actor
    @request = request
  end

  def save_weekly(input)
    scope = @doctor.schedules.weekly.where(weekday: input.keys)
    save(scope) do |current, night_enabled|
      start_dates = current.group_by(&:weekday).transform_values { |rows| rows.map(&:start_date).min }
      today = Date.current
      rows = input.flat_map do |weekday, fields|
        day = weekday.to_i
        parse_shifts(fields, night_enabled, Schedule::WEEKDAYS.fetch(day)).map do |shift|
          shift.merge(weekday: day, start_date: start_dates.fetch(day, today))
        end
      end
      rows += current.select(&:night?).map { |rule| rule.slice(:weekday, :start_date, :time_slot, :capacity).symbolize_keys } unless night_enabled
      rows
    end
  end

  def save_date(date, input)
    save(@doctor.schedules.on_date(date), date: date) do |_current, night_enabled|
      shifts = parse_shifts(input, night_enabled, date.iso8601)
      shifts = [ { time_slot: "OFF", capacity: nil } ] if shifts.empty?
      shifts.map { |shift| shift.merge(weekday: date.wday, start_date: date, end_date: date) }
    end
  end

  def revoke_date(date)
    target = nil
    @doctor.with_lock(requires_new: true) do
      rows = @doctor.schedules.on_date(date).order(:id)
      target = rows.first
      if target
        rows.delete_all
        audit(:revoke, target, date: date)
      end
    end
    true
  rescue ActiveRecord::ActiveRecordError
    errors.add(:base, REVOKE_FAILURE)
    audit(:revoke, target, date: date, status: "failed", reason: REVOKE_FAILURE)
    false
  end

  private

  def save(scope, date: nil)
    action = :update
    target = nil
    @doctor.with_lock(requires_new: true) do
      current = scope.active.order(:id).to_a
      action = :create if current.empty?
      target = current.first
      shifts = yield(current, Schedule.night_enabled?)
      changed = replace(current, shifts)
      audit(action, changed, date: date) if changed
    end
    true
  rescue Invalid, ActiveRecord::ActiveRecordError => error
    errors.add(:base, error.is_a?(Invalid) ? error.message : FAILURE)
    audit(action, target, date: date, status: "failed", reason: FAILURE)
    false
  end

  def replace(current, shifts)
    remaining = current.dup
    changed = []
    shifts.each do |shift|
      rule = remaining.find { |row| row.weekday == shift[:weekday] && row.time_slot == shift[:time_slot] }
      if rule
        remaining.delete(rule)
        if rule.capacity != shift[:capacity]
          rule.update!(capacity: shift[:capacity])
          changed << rule
        end
      else
        changed << @doctor.schedules.create!(shift)
      end
    end
    remaining.each(&:destroy!)
    changed.first || remaining.first
  end

  def parse_shifts(fields, night_enabled, label)
    slot = fields[:time_slot].presence
    night = fields[:night].presence
    raise Invalid, "#{label}：请选择有效的日间班次" if slot && !Schedule::DAY_SLOTS.key?(slot)
    raise Invalid, "#{label}：晚班选项无效" if night && !%w[0 1].include?(night)
    raise Invalid, "#{label}：医院尚未启用晚班" if night == "1" && !night_enabled

    shifts = []
    shifts << { time_slot: slot, capacity: capacity(fields[:capacity], label, "日间号数") } if slot
    shifts << { time_slot: "NIGHT", capacity: capacity(fields[:night_capacity], label, "晚班号数") } if night == "1"
    shifts
  end

  def capacity(input, label, field)
    return if input.blank?

    value = input.to_s
    if /\A[0-9]{1,10}\z/.match?(value) && (1...2**31).cover?(value.to_i)
      return value.to_i
    end
    raise Invalid, "#{label}：#{field}请输入正整数或留空"
  end

  def audit(action, target, date:, status: "success", reason: nil)
    details = { doctor_id: @doctor.id, schedule_mode: (date ? "指定日期调整" : "每周排班"),
      schedule_date: date&.iso8601, reason: reason }.compact
    Log.record!(category: "booking", action: "schedule.#{action}", actor: @actor, target: target,
      request: @request, status: status, details: details)
  end
end

class ScheduleCalendar
  DAYS = 14
  SHIFT_LABELS = Schedule::DAY_SLOTS.merge("NIGHT" => "晚班").freeze
  CUTOFF_HOURS = { "AM" => 12, "PM" => 17, "FULL" => 17, "NIGHT" => 21 }.freeze
  Day = Data.define(:adjusted, :off, :shifts)

  def initialize(doctor_ids, dates, settings: AppointmentSettings.new, night_enabled: settings.night_enabled?)
    @doctor_ids = doctor_ids
    @dates = dates
    @night_enabled = night_enabled
    @default_capacity = settings.default_capacity
    rules = Schedule.active.where(doctor_id: doctor_ids, start_date: ..dates.last)
      .where("end_date IS NULL OR (end_date = start_date AND start_date >= ?)", dates.first).order(:id).to_a
    weekly, adjustments = rules.partition(&:weekly?)
    @weekly = weekly.group_by { |rule| [ rule.doctor_id, rule.weekday ] }
    @adjustments = adjustments.group_by { |rule| [ rule.doctor_id, rule.start_date ] }
  end

  def day(doctor_id, date)
    adjustment = @adjustments[[ doctor_id, date ]]
    rules = adjustment || @weekly.fetch([ doctor_id, date.wday ], []).select { |rule| rule.start_date <= date }
    return Day.new(adjusted: true, off: true, shifts: []) if rules.any?(&:off?)

    # A stored adjustment still replaces the week when the hospital hides night shifts.
    shifts = @night_enabled ? rules : rules.reject(&:night?)
    Day.new(adjusted: adjustment.present?, off: false, shifts: shifts.sort_by { |rule| rule.night? ? 1 : 0 })
  end

  def day_availability(doctor_id, date)
    effective = day(doctor_id, date)
    shifts = effective.shifts.map do |rule|
      slot = rule.time_slot
      total = rule.capacity || @default_capacity
      remaining = [ total - occupied_counts.fetch([ doctor_id, date, slot ], 0), 0 ].max
      { time_slot: slot, label: SHIFT_LABELS.fetch(slot), total: total, remaining: remaining }
    end
    { adjusted: effective.adjusted, off: effective.off, shifts: shifts }
  end

  def as_json(*)
    @dates.map do |date|
      availability = @doctor_ids.each_with_object({}) do |id, result|
        shifts = day_availability(id, date).fetch(:shifts).map do |shift|
          cutoff = date.in_time_zone.change(hour: CUTOFF_HOURS.fetch(shift.fetch(:time_slot)))
          shift.merge(cutoff_at: cutoff.to_i * 1000)
        end
        result[id.to_s] = shifts if shifts.any?
      end
      doctors = availability.transform_values { |shifts| shifts.pluck(:time_slot) }
      { date: date.iso8601, doctors: doctors, availability: availability }
    end
  end

  private

  # Formal appointments are not stored yet. Load their counts for @doctor_ids and @dates here when booking opens.
  def occupied_counts
    @occupied_counts ||= {}
  end
end

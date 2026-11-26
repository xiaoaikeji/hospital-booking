class ScheduleCalendar
  DAYS = 14
  Day = Data.define(:adjusted, :off, :shifts)

  def initialize(doctor_ids, dates, night_enabled: Schedule.night_enabled?)
    @doctor_ids = doctor_ids
    @dates = dates
    @night_enabled = night_enabled
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

  def as_json(*)
    @dates.map do |date|
      doctors = @doctor_ids.each_with_object({}) do |id, result|
        slots = day(id, date).shifts.map(&:time_slot)
        result[id.to_s] = slots if slots.any?
      end
      { date: date.iso8601, doctors: doctors }
    end
  end
end

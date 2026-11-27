class ScheduleCalendar
  DAYS = 14
  SHIFT_LABELS = Schedule::DAY_SLOTS.merge("NIGHT" => "晚班").freeze
  Day = Data.define(:adjusted, :off, :shifts)

  def initialize(doctor_ids, dates, settings: AppointmentSettings.new, night_enabled: settings.night_enabled?)
    @doctor_ids = doctor_ids
    @dates = dates
    @night_enabled = night_enabled
    @settings = settings
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

  def day_availability(doctor_id, date, include_times: false)
    effective = day(doctor_id, date)
    shifts = effective.shifts.map { |rule| shift_availability(rule, date, include_times: include_times) }
    { adjusted: effective.adjusted, off: effective.off, shifts: shifts }
  end

  def as_json(options = nil)
    legacy_timed_schedule = @settings.time_slot_booking? && !options&.fetch(:time_slots, false)
    @dates.map do |date|
      availability = @doctor_ids.each_with_object({}) do |id, result|
        shifts = day_availability(id, date, include_times: true).fetch(:shifts)
        if legacy_timed_schedule
          # Older pickers can only select an entire shift.
          shifts = shifts.map { |shift| shift[:slots] ? shift.except(:slots).merge(remaining: 0) : shift }
        end
        result[id.to_s] = shifts if shifts.any?
      end
      # Early clients use this list alone and consider all listed shifts selectable.
      doctors = legacy_timed_schedule ? {} : availability.transform_values { |shifts| shifts.pluck(:time_slot) }
      { date: date.iso8601, doctors: doctors, availability: availability }
    end
  end

  private

  def shift_availability(rule, date, include_times:)
    shift = rule.time_slot
    counts = occupied_counts.fetch([ rule.doctor_id, date, shift ], {})
    total = if @settings.time_slot_booking?
      limit = @settings.time_slot_capacity(shift)
      [ rule.capacity || limit, limit ].min
    else
      rule.capacity || @settings.default_capacity
    end
    remaining = [ total - counts.values.sum, 0 ].max
    availability = { time_slot: shift, label: SHIFT_LABELS.fetch(shift), total: total, remaining: remaining }
    return availability unless include_times

    ranges = @settings.slot_ranges(shift)
    midnight = date.in_time_zone
    cutoff = @settings.time_slot_booking? ? ranges.last.end - 1 : ranges.last.end
    availability.merge!(time_range(midnight, ranges.first.begin, ranges.last.end, cutoff: cutoff))
    if @settings.time_slot_booking?
      availability[:slots] = ranges.flat_map do |range|
        range.map { |index| time_range(midnight, index, index + 1, cutoff: index) }
      end
      future_seats = 0
      per_slot = @settings.max_bookings_per_slot
      availability[:slots].reverse_each do |slot|
        free = [ per_slot - counts.fetch(slot[:start_time], 0), 0 ].max
        future_seats += free
        slot[:remaining] = [ remaining, free ].min
        # The shift figure for when this is the first slot that hasn't started.
        slot[:shift_available] = [ remaining, future_seats ].min
      end
    end
    availability
  end

  def time_range(midnight, start_index, end_index, cutoff:)
    {
      start_time: AppointmentSettings::SLOT_TIMES.fetch(start_index),
      end_time: AppointmentSettings::SLOT_TIMES.fetch(end_index),
      cutoff_at: (midnight.to_i + cutoff * AppointmentSettings::SLOT_MINUTES * 60) * 1000
    }
  end

  # Formal bookings are not persisted yet. Group them by [doctor_id, date, shift]
  # when booking opens, with counts keyed by local start time (nil for whole-shift bookings).
  def occupied_counts
    @occupied_counts ||= {}
  end
end

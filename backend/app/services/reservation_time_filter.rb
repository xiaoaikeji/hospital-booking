class ReservationTimeFilter
  SHIFTS = { "AM" => "上午", "PM" => "下午", "NIGHT" => "晚班", "FULL" => "全天整班" }.freeze
  WINDOWS = AppointmentSettings::SLOT_TIMES.each_cons(2).map { |times| times.join("–") }.freeze

  def self.valid?(value) = SHIFTS.key?(value) || WINDOWS.include?(value)

  def initialize(records)
    @records = records
    zone = Appointment.connection.quote(Time.zone.tzinfo.name)
    @start_clock = "(booking_start_at AT TIME ZONE #{zone})::time"
  end

  def options
    starts = half_hours.unscope(:order, :select).distinct.pluck(Arel.sql("to_char(#{@start_clock}, 'HH24:MI')"))
    SHIFTS.invert.to_a + WINDOWS.select { |window| starts.include?(window.first(5)) }
  end

  def matching(value)
    return @records unless value
    if SHIFTS.key?(value)
      whole = @records.where(time_slot: value, booking_start_at: nil, booking_end_at: nil)
      return whole if value == "FULL"

      range = AppointmentSettings.new.slot_ranges(value).sole
      times = AppointmentSettings::SLOT_TIMES
      timed = @records.where.not(booking_end_at: nil)
        .where("#{@start_clock} >= ?::time AND #{@start_clock} < ?::time", times[range.begin], times[range.end])
      whole.or(timed)
    else
      half_hours.where("#{@start_clock} = ?::time", value.first(5))
    end
  end

  private

  def half_hours
    @records.where("booking_end_at = booking_start_at + interval '30 minutes'")
  end
end

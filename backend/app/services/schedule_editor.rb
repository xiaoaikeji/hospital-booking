class ScheduleEditor
  include ActiveModel::Model

  FIELDS = %i[time_slot capacity night night_capacity].freeze
  REVISION_FIELDS = %w[id weekday start_date end_date time_slot capacity is_active updated_at].freeze
  STALE = "排班已被修改，已加载最新排班，请核对后重新操作"
  FAILURE = "排班未保存，请重试"
  REVOKE_FAILURE = "日期调整未撤销，请重试"
  class Invalid < StandardError; end
  class Stale < Invalid; end
  attr_reader :affected_bookings

  def initialize(doctor:, actor:, request:)
    @doctor = doctor
    @actor = actor
    @request = request
  end

  def weekly_revision
    revision_for(@doctor.schedules.weekly.order(:id))
  end

  def date_revision(date)
    rows = @doctor.schedules.on_date(date).order(:id).to_a
    if rows.none?(&:is_active)
      rows.concat(@doctor.schedules.weekly.active.where(weekday: date.wday, start_date: ..date).order(:id))
    end
    revision_for(rows, date: date)
  end

  def stale? = errors.of_kind?(:base, :stale)

  def save_weekly(input, revision:)
    scope = @doctor.schedules.weekly.where(weekday: input.keys)
    save(scope, revision: revision) do |current, night_enabled|
      by_weekday = current.group_by(&:weekday)
      today = Date.current
      input.flat_map do |weekday, fields|
        day = weekday.to_i
        previous = by_weekday.fetch(day, [])
        start_date = previous.map(&:start_date).min || today
        parse_shifts(fields, night_enabled, Schedule::WEEKDAYS.fetch(day), previous: previous).map do |shift|
          shift.merge(weekday: day, start_date: start_date)
        end
      end
    end
  end

  def save_date(date, input, revision:)
    @affected_bookings = {}
    save(@doctor.schedules.on_date(date), date: date, revision: revision) do |current, night_enabled|
      calendar = ScheduleCalendar.new([ @doctor.id ], date..date, night_enabled: true)
      inherited = current.empty? && (!night_enabled || !input.key?(:night))
      previous = inherited ? calendar.day(@doctor.id, date).shifts : current

      shifts = parse_shifts(input, night_enabled, date.iso8601, previous: previous)
      # Only an existing shift can stay inherited. An empty day needs an explicit OFF.
      next [] if inherited && shifts.any? && shifts == previous.map { |rule| shift_attributes(rule) }

      @affected_bookings = calendar.booked_counts(@doctor.id, date).except(*shifts.pluck(:time_slot)).select { |_shift, count| count.positive? }
      shifts << { time_slot: "OFF", capacity: nil } if shifts.empty?
      shifts.map { |shift| shift.merge(weekday: date.wday, start_date: date, end_date: date) }
    end
  end

  def revoke_date(date, revision:)
    target = nil
    @doctor.with_lock(requires_new: true) do
      raise ActiveRecord::RecordNotFound if @doctor.deleted_at?

      rows = @doctor.schedules.on_date(date).order(:id)
      target = rows.first
      check_revision!(revision, date)
      if target
        rows.delete_all
        audit(:revoke, target, date: date)
      end
    end
    true
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Stale, ActiveRecord::ActiveRecordError => error
    record_failure(error, :revoke, target, date: date, fallback: REVOKE_FAILURE)
  end

  private

  def revision_for(rows, date: nil)
    attributes = rows.map { |row| row.attributes.values_at(*REVISION_FIELDS) }
    Digest::SHA256.hexdigest([ @doctor.id, date, attributes ].to_json)
  end

  def check_revision!(revision, date)
    current = date ? date_revision(date) : weekly_revision
    raise Stale, STALE unless revision == current
  end

  def save(scope, revision:, date: nil)
    action = :update
    target = nil
    @doctor.with_lock(requires_new: true) do
      raise ActiveRecord::RecordNotFound if @doctor.deleted_at?

      current = scope.active.order(:id).to_a
      action = :create if current.empty?
      target = current.first
      check_revision!(revision, date)
      shifts = yield(current, Schedule.night_enabled?)
      changed = replace(current, shifts)
      audit(action, changed, date: date) if changed
    end
    true
  rescue ActiveRecord::RecordNotFound
    raise
  rescue Invalid, ActiveRecord::ActiveRecordError => error
    record_failure(error, action, target, date: date, fallback: FAILURE)
  end

  def record_failure(error, action, target, date:, fallback:)
    if error.is_a?(Stale)
      errors.add(:base, :stale, message: STALE)
      reason = STALE
    else
      errors.add(:base, error.is_a?(Invalid) ? error.message : fallback)
      reason = fallback
    end
    audit(action, target, date: date, status: "failed", reason: reason)
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

  def parse_shifts(fields, night_enabled, label, previous:)
    slot = fields[:time_slot].presence
    night = fields[:night]
    raise Invalid, "#{label}：请选择有效的日间班次" if slot && !Schedule::DAY_SLOTS.key?(slot)
    raise Invalid, "#{label}：晚班选项无效" if fields.key?(:night) && !%w[0 1].include?(night)
    raise Invalid, "#{label}：医院尚未启用晚班，请刷新页面后重试" if night == "1" && !night_enabled

    shifts = []
    shifts << { time_slot: slot, capacity: capacity(fields[:capacity], label, "日间号数") } if slot
    if night == "1"
      shifts << { time_slot: "NIGHT", capacity: capacity(fields[:night_capacity], label, "晚班号数") }
    elsif night.nil? || !night_enabled
      shifts.concat(previous.select(&:night?).map { |rule| shift_attributes(rule) })
    end
    shifts
  end

  def shift_attributes(rule) = { time_slot: rule.time_slot, capacity: rule.capacity }

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

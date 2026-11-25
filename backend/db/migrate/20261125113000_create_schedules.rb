class CreateSchedules < ActiveRecord::Migration[8.1]
  def change
    create_table :schedules do |t|
      t.references :doctor, null: false, foreign_key: true
      t.integer :weekday, limit: 2, null: false
      t.date :start_date, null: false
      t.date :end_date
      t.string :time_slot, limit: 10, null: false
      t.integer :capacity
      t.boolean :is_active, default: true, null: false
      t.timestamps type: :timestamptz

      t.check_constraint "weekday BETWEEN 0 AND 6", name: "schedules_weekday_allowed"
      t.check_constraint "end_date >= start_date", name: "schedules_dates_ordered"
      t.check_constraint "end_date IS DISTINCT FROM start_date OR weekday = EXTRACT(DOW FROM start_date)",
        name: "schedules_single_day_weekday_matches"
      t.check_constraint "time_slot IN ('FULL', 'AM', 'PM', 'NIGHT', 'OFF')", name: "schedules_time_slot_allowed"
      t.check_constraint "time_slot <> 'OFF' OR (end_date IS NOT NULL AND end_date = start_date AND capacity IS NULL)",
        name: "schedules_off_single_day"
      t.check_constraint "capacity >= 0", name: "schedules_capacity_nonnegative"
    end
  end
end

class RecordWechatExperienceTime < ActiveRecord::Migration[8.1]
  def change
    add_column :mini_program_releases, :confirmed_experience_time, :bigint
  end
end

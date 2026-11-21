class MiniProgramRelease < ApplicationRecord
  belongs_to :app
  belongs_to :operator, class_name: "Admin"
  belongs_to :previous_build, class_name: "MiniProgramRelease", optional: true
  has_many :mini_program_audits
end

class MiniProgramAudit < ApplicationRecord
  belongs_to :app
  belongs_to :mini_program_release, optional: true
  belongs_to :operator, class_name: "Admin"
end

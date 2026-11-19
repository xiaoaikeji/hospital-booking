class MiniProgramRelease < ApplicationRecord
  belongs_to :app
  belongs_to :operator, class_name: "Admin"
  validates :version, :description, presence: true
  validates :template_id, format: { with: /\A\d+\z/ }
  LABELS = { "upload_unknown" => "上传结果待核实", "uploaded" => "已上传", "upload_failed" => "上传失败", "closed" => "已关闭" }.freeze
end

class MiniProgramAudit < ApplicationRecord
  belongs_to :app
  belongs_to :mini_program_release, optional: true
  belongs_to :operator, class_name: "Admin"
  PENDING = %w[submit_unknown pending delayed withdraw_unknown].freeze
  LABELS = { "submit_unknown" => "提审结果待核实", "not_accepted" => "未受理", "pending" => "审核中", "delayed" => "审核延后",
    "passed" => "审核通过", "rejected" => "被拒", "withdraw_unknown" => "撤回待核实", "withdrawn" => "已撤回" }.freeze
  PUBLICATIONS = { "unpublished" => "未发布", "publish_unknown" => "发布结果待核实", "failed" => "发布失败", "published" => "已发布" }.freeze
  scope :pending, -> { where(status: PENDING) }
  scope :accepted_or_uncertain, -> { where.not(status: "not_accepted") }
end

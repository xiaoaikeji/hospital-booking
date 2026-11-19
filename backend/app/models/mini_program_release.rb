class MiniProgramRelease < ApplicationRecord
  SNAPSHOT_FIELDS = %w[template_id template_type version description ext_config].freeze
  belongs_to :previous_build, class_name: "MiniProgramRelease", optional: true
  belongs_to :app
  belongs_to :operator, class_name: "Admin"
  has_many :mini_program_audits
  has_one :effective_audit, -> { accepted_or_uncertain.order(id: :desc) }, class_name: "MiniProgramAudit"
  has_one :latest_audit, -> { order(id: :desc) }, class_name: "MiniProgramAudit"

  validates :version, :description, presence: true
  validates :template_id, format: { with: /\A\d+\z/ }
  validates :template_type, inclusion: { in: WechatPlatform::CodeTemplates::TYPES.keys }
  attr_readonly :app_id, :operator_id, :template_id, :template_type, :ext_config, :version, :description, :restored_for_id
  before_validation :snapshot_ext_config, on: :create

  LABELS = { "upload_unknown" => "上传结果待核实", "uploaded" => "已上传", "upload_failed" => "上传失败", "closed" => "已关闭" }.freeze
  STATES = LABELS.merge(MiniProgramAudit::LABELS, MiniProgramAudit::PUBLICATIONS.except("unpublished"), "auto_wait" => "等待自动发布").freeze
  IN_PROGRESS = %w[upload_unknown submit_unknown pending delayed withdraw_unknown publish_unknown auto_wait].freeze

  # 筛选和状态标签共用业务阶段；待核实操作仍保留原始 progress，用于决定可执行的动作。
  STAGES = {
    "uploading" => ["上传中", %w[upload_unknown]],
    "uploaded" => ["已上传", %w[uploaded not_accepted]],
    "upload_failed" => ["上传失败", %w[upload_failed]],
    "pending" => ["审核中", %w[pending submit_unknown withdraw_unknown]],
    "delayed" => ["审核延后", %w[delayed]],
    "rejected" => ["审核拒绝", %w[rejected]],
    "passed" => ["审核通过", %w[passed auto_wait publish_unknown]],
    "withdrawn" => ["已撤回", %w[withdrawn]],
    "published" => ["已发布", %w[published]],
    "failed" => ["发布失败", %w[failed]],
    "closed" => ["已关闭", %w[closed]]
  }.freeze
  STAGE_BY_PROGRESS = STAGES.flat_map { |stage, (_, values)| values.map { |value| [value, stage] } }.to_h.freeze

  # 未受理的重提不能覆盖上一有效审核单；更新时间仍包括每次尝试。
  scope :with_progress, -> {
    joins(:app).joins(<<~SQL)
      LEFT JOIN LATERAL (
        SELECT *, MAX(updated_at) OVER () AS last_change FROM mini_program_audits
        WHERE mini_program_release_id = mini_program_releases.id
        ORDER BY (status <> 'not_accepted') DESC, id DESC LIMIT 1
      ) recent ON TRUE
      CROSS JOIN LATERAL (SELECT CASE
        WHEN mini_program_releases.status <> 'uploaded' OR recent.id IS NULL THEN mini_program_releases.status
        WHEN recent.publication <> 'unpublished' THEN recent.publication
        WHEN recent.status = 'passed' AND recent.auto_publish AND recent.id =
          (SELECT MAX(id) FROM mini_program_audits WHERE app_id = mini_program_releases.app_id AND status <> 'not_accepted') THEN 'auto_wait'
        ELSE recent.status END AS progress) progress_row
    SQL
      .select("mini_program_releases.*, progress_row.progress, GREATEST(mini_program_releases.updated_at, recent.last_change) AS activity_at")
  }

  def action_round = effective_audit || latest_audit

  private

  def snapshot_ext_config
    return unless app && !source_release_id
    self.ext_config = { extAppid: app.appid }
    if template_type == "normal"
      self.ext_config = ext_config.merge(extEnable: true, ext: { provider: app.provider, appid: app.appid })
    end
  end
end

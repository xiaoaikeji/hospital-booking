class Department < DirectoryEntry
  PARENT_LOCK_ID = 71_020_021

  belongs_to :parent, class_name: "Department", optional: true
  has_many :children, class_name: "Department", foreign_key: :parent_id, inverse_of: :parent
  has_many :doctor_departments
  has_many :doctors, through: :doctor_departments

  validate :parent_forms_tree, if: -> { parent_id.present? && will_save_change_to_parent_id? }

  def self.booking_rows
    children = ordered.with_attached_image.to_a.group_by(&:parent_id)
    pending = children.fetch(nil, []).reverse.map { |entry| [ entry, 0 ] }
    rows = []
    until pending.empty?
      entry, depth = pending.pop
      next unless entry.enabled?

      rows << [ entry, depth ]
      children.fetch(entry.id, []).reverse_each { |child| pending << [ child, depth + 1 ] }
    end
    rows
  end

  def visible_in_booking?
    entry = self
    seen = Set.new
    while entry&.enabled? && seen.add?(entry.id)
      return true if entry.parent_id.nil?

      entry = entry.parent
    end
    false
  end

  def path_in(departments)
    path = []
    entry = self
    seen = Set.new
    while entry && seen.add?(entry.id)
      path << entry
      entry = departments[entry.parent_id]
    end
    path.reverse
  end

  private

  def parent_forms_tree
    # Parent changes on different rows can form a cycle even when each form was valid when opened.
    self.class.connection_pool.with_connection do |connection|
      connection.execute("SELECT pg_advisory_xact_lock(#{PARENT_LOCK_ID})")
    end
    parents = self.class.pluck(:id, :parent_id).to_h
    unless parents.key?(parent_id)
      errors.add(:parent_id, "上级科室不存在，请重新选择")
      return
    end

    seen = Set.new([ id ])
    ancestor = parent_id
    while ancestor
      unless seen.add?(ancestor)
        errors.add(:parent_id, "上级科室不能是自身或其下级科室")
        return
      end
      ancestor = parents[ancestor]
    end
  end
end

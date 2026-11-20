class PageLinkConfiguration
  Group = Data.define(:source, :records, :effective)
  SUPPORTED_TYPES = { "wechat" => Link::TYPES.keys.freeze }.freeze

  def initialize(app: nil)
    @app = app
  end

  def groups
    @groups ||= begin
      allowed_types = SUPPORTED_TYPES.fetch(@app ? @app.provider : "wechat", [])
      records = Link.none
      if allowed_types.any?
        records = Link.where(app_id: [ nil, @app&.id ].uniq).with_attached_image.ordered
      end
      by_position = records.group_by(&:position)

      Link::POSITIONS.keys.index_with do |position|
        options = by_position.fetch(position, [])
        overrides, shared = options.partition { |link| link.app_id.present? }
        source, selected = overrides.any? ? [ :app, overrides ] : [ :shared, shared ]
        effective = selected.select { |link| link.active? && allowed_types.include?(link.link_type) }
        Group.new(source:, records: selected, effective:)
      end
    end
  end
end

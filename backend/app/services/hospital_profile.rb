class HospitalProfile
  include ActiveModel::Model
  include ActiveModel::Attributes

  KEY = "hospital"
  TEXT_FIELDS = %w[company_name address mobile time_range introduction announcement].freeze
  HOME_PHONE_FIELD = "show_phone_on_homepage"
  COORDINATE_FIELDS = { "address_longitude" => (-180..180), "address_latitude" => (-90..90) }.freeze
  FIELDS = [ *TEXT_FIELDS, HOME_PHONE_FIELD, *COORDINATE_FIELDS.keys ].freeze
  FAILURE = "医院资料未保存，请重试"
  INVALID_LOCATION = "医院坐标无效，请重新地图选点"

  class InvalidLocation < StandardError; end

  TEXT_FIELDS.each { |field| attribute field, :string }
  COORDINATE_FIELDS.each_key { |field| attribute field, :float }
  attribute HOME_PHONE_FIELD, :boolean, default: false
  attr_reader :record, :location_submitted

  def initialize
    @record = self.class.load_record
    stored = @record&.settings || {}
    super(stored.slice(*TEXT_FIELDS, HOME_PHONE_FIELD).merge(coordinates(stored) || {}))
  end

  def self.load_record
    Setting.with_attached_hospital_image.find_by(key: KEY)
  end

  def public_values
    stored = record&.settings || {}
    stored.slice(*TEXT_FIELDS).merge(HOME_PHONE_FIELD => show_phone_on_homepage == true).merge(coordinates(stored) || {})
  end

  def save(input, actor:, request:)
    audit = { category: "settings", action: "hospital.update", actor: actor, request: request }
    updates = input.slice(*FIELDS).to_h
    point = updates.slice(*COORDINATE_FIELDS.keys)
    if point.any?
      raise InvalidLocation unless point.size == COORDINATE_FIELDS.size

      location = point.values.all?(&:blank?) ? point.transform_values { nil } : coordinates(point)
      raise InvalidLocation unless location

      updates.merge!(location)
      @location_submitted = true
    end
    assign_attributes(updates)
    if input[:image].present?
      StorageConfiguration.refresh!
      MediaUpload.attach(input[:image], as: :hospital_image) { |blob| persist(audit, updates.keys, blob:) }
    else
      persist(audit, updates.keys, remove_image: input[:remove_image] == "1")
    end
    true
  rescue InvalidLocation, MediaUpload::Invalid, MediaUpload::Failed, IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    @record = self.class.load_record
    reason = error.is_a?(InvalidLocation) ? INVALID_LOCATION : FAILURE
    Log.record!(**audit, target: record, status: "failed", details: { reason: reason })
    raise if error.is_a?(IntegrationSettings::ConfigurationError)

    if error.is_a?(MediaUpload::Invalid) || error.is_a?(MediaUpload::Failed)
      errors.add(:image, error.message)
    else
      errors.add(:base, reason)
    end
    false
  end

  private

  # Stored and published coordinates use GCJ-02, as required by wx.openLocation.
  def coordinates(values)
    point = COORDINATE_FIELDS.to_h do |field, range|
      coordinate = Float(values[field], exception: false)
      return unless coordinate && range.cover?(coordinate)

      [ field, coordinate.round(7) ]
    end
    point unless point.values.all?(&:zero?)
  end

  def persist(audit, updated_fields, blob: nil, remove_image: false)
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: KEY } ], unique_by: :key)
      @record = Setting.lock.find_by!(key: KEY)
      fields = updated_fields.select do |field|
        previous = record.settings[field]
        if field == HOME_PHONE_FIELD
          value = show_phone_on_homepage == true
          previous = ActiveModel::Type::Boolean.new.cast(previous) == true
        elsif COORDINATE_FIELDS.key?(field)
          value = public_send(field)
        else
          value = public_send(field).to_s.gsub(/\r\n?/, "\n").strip.presence
        end
        next false if previous == value

        record.write_value(field, value)
        true
      end
      if blob || (remove_image && record.hospital_image.attached?)
        record.hospital_image = blob
        fields << "image"
      end
      if fields.any?
        record.save!
        Log.record!(**audit, target: record, details: { fields: fields })
      end
    end
  end
end

class HospitalProfile
  include ActiveModel::Model
  include ActiveModel::Attributes

  KEY = "hospital"
  TEXT_FIELDS = %w[company_name address mobile time_range introduction announcement].freeze
  HOME_PHONE_FIELD = "show_phone_on_homepage"
  FIELDS = [ *TEXT_FIELDS, HOME_PHONE_FIELD ].freeze
  FAILURE = "医院资料未保存，请重试"

  TEXT_FIELDS.each { |field| attribute field, :string }
  attribute HOME_PHONE_FIELD, :boolean, default: false
  attr_reader :record

  def initialize
    @record = self.class.load_record
    super(@record ? @record.settings.slice(*FIELDS) : {})
  end

  def self.load_record
    Setting.with_attached_hospital_image.find_by(key: KEY)
  end

  def public_values
    (record&.settings || {}).slice(*TEXT_FIELDS).merge(HOME_PHONE_FIELD => show_phone_on_homepage == true)
  end

  def save(input, actor:, request:)
    updates = input.slice(*FIELDS)
    assign_attributes(updates)
    audit = { category: "settings", action: "hospital.update", actor: actor, request: request }
    if input[:image].present?
      StorageConfiguration.refresh!
      MediaUpload.attach(input[:image], as: :hospital_image) { |blob| persist(audit, updates.keys, blob:) }
    else
      persist(audit, updates.keys, remove_image: input[:remove_image] == "1")
    end
    true
  rescue MediaUpload::Invalid, MediaUpload::Failed, IntegrationSettings::ConfigurationError, ActiveRecord::ActiveRecordError => error
    @record = self.class.load_record
    Log.record!(**audit, target: record, status: "failed", details: { reason: FAILURE })
    raise if error.is_a?(IntegrationSettings::ConfigurationError)

    if error.is_a?(MediaUpload::Invalid) || error.is_a?(MediaUpload::Failed)
      errors.add(:image, error.message)
    else
      errors.add(:base, FAILURE)
    end
    false
  end

  private

  def persist(audit, updated_fields, blob: nil, remove_image: false)
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: KEY } ], unique_by: :key)
      @record = Setting.lock.find_by!(key: KEY)
      fields = updated_fields.select do |field|
        previous = record.settings[field]
        if field == HOME_PHONE_FIELD
          value = show_phone_on_homepage == true
          previous = ActiveModel::Type::Boolean.new.cast(previous) == true
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

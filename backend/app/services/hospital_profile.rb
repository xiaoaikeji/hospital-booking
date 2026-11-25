class HospitalProfile
  include ActiveModel::Model
  include ActiveModel::Attributes

  KEY = "hospital"
  FIELDS = %w[company_name address mobile time_range introduction].freeze
  FAILURE = "医院资料未保存，请重试"

  FIELDS.each { |field| attribute field, :string }
  attr_reader :record

  def initialize
    @record = self.class.load_record
    super(@record ? @record.settings.slice(*FIELDS) : {})
  end

  def self.load_record
    Setting.with_attached_hospital_image.find_by(key: KEY)
  end

  def save(input, actor:, request:)
    updates = input.slice(*FIELDS)
    assign_attributes(updates)
    audit = { category: "settings", action: "hospital.update", actor: actor, request: request }
    if input[:image].present?
      MediaUpload.attach(input[:image], as: :hospital_image) { |blob| persist(audit, updates.keys, blob:) }
    else
      persist(audit, updates.keys, remove_image: input[:remove_image] == "1")
    end
    true
  rescue MediaUpload::Invalid, MediaUpload::Failed, ActiveRecord::ActiveRecordError => error
    @record = self.class.load_record
    if error.is_a?(MediaUpload::Invalid) || error.is_a?(MediaUpload::Failed)
      errors.add(:image, error.message)
    else
      errors.add(:base, FAILURE)
    end
    Log.record!(**audit, target: record, status: "failed", details: { reason: FAILURE })
    false
  end

  private

  def persist(audit, updated_fields, blob: nil, remove_image: false)
    Setting.transaction(requires_new: true) do
      Setting.insert_all([ { key: KEY } ], unique_by: :key)
      @record = Setting.lock.find_by!(key: KEY)
      fields = updated_fields.select do |field|
        value = public_send(field).to_s.strip.presence
        next false if record.settings[field] == value

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

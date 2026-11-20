class PosterSaving
  def self.call(poster, attributes:, file: nil, actor:, request: nil)
    poster.assign_attributes(attributes)
    layout_edited = layout_changed?(poster)
    if file.present?
      MediaUpload.new(file, as: :poster_background).validate!
      file.tempfile.rewind
      image = MiniMagick::Image.read(file.tempfile)
      width, height = image.dimensions
      if width > Poster::MAX_SIDE || height > Poster::MAX_SIDE || width * height > Poster::MAX_PIXELS
        raise MediaUpload::Invalid, "图片最长边不超过 6000 像素且总像素不超过 1800 万"
      end
      image.auto_orient
      image.strip
      normalized = ActionDispatch::Http::UploadedFile.new(tempfile: File.open(image.path, "rb"), filename: file.original_filename, type: file.content_type)
      MediaUpload.attach(normalized, as: :poster_background) do |blob|
        poster.image_width, poster.image_height = image.dimensions
        if poster.new_record?
          default_layout(poster)
        elsif !layout_edited
          fit_layout(poster)
        end
        blob.update!(metadata: { width: poster.image_width, height: poster.image_height, analyzed: true })
        poster.background = blob
        save!(poster, actor, request)
      end
    else
      save!(poster, actor, request)
    end
    true
  rescue ActiveRecord::RecordInvalid
    poster.attachment_changes.delete("background")
    if file.present? && poster.persisted?
      poster.restore_attributes(%w[image_width image_height])
      poster.restore_attributes(%w[qr_x qr_y qr_size]) unless layout_edited
    end
    poster.errors.add(:base, "海报未能保存，请稍后重试") if poster.errors.empty?
    false
  rescue MediaUpload::Invalid, MediaUpload::Failed => error
    poster.errors.add(:background, error.message)
    false
  rescue MiniMagick::Error
    poster.errors.add(:background, "无法读取图片，请重新选择 JPG、PNG 或 WEBP 图片")
    false
  ensure
    normalized&.tempfile&.close
    image&.destroy!
  end

  def self.layout_changed?(poster)
    return false if poster.new_record?
    %i[qr_x qr_y qr_size].any? do |attribute|
      poster.will_save_change_to_attribute?(attribute) ||
        poster.read_attribute_before_type_cast(attribute).to_s != poster.attribute_in_database(attribute).to_s
    end
  end

  def self.default_layout(poster)
    min_side = [ poster.image_width, poster.image_height ].min
    poster.qr_size = [ min_side * 24 / 100, 1 ].max
    margin = min_side * 6 / 100
    poster.qr_x = (poster.image_width - poster.qr_size - margin).clamp(0, poster.image_width - poster.qr_size)
    poster.qr_y = (poster.image_height - poster.qr_size - margin).clamp(0, poster.image_height - poster.qr_size)
  end

  def self.fit_layout(poster)
    return unless [ poster.qr_x, poster.qr_y, poster.qr_size ].all? { |n| n.is_a?(Integer) } &&
      poster.qr_size.positive? && poster.qr_x >= 0 && poster.qr_y >= 0
    poster.qr_size = [ poster.qr_size, poster.image_width, poster.image_height ].min
    poster.qr_x = [ poster.qr_x, poster.image_width - poster.qr_size ].min
    poster.qr_y = [ poster.qr_y, poster.image_height - poster.qr_size ].min
  end

  def self.save!(poster, actor, request)
    Poster.transaction do
      poster.save!
      Log.record!(category: "poster", action: "poster.save", actor: actor, target: poster, request: request,
        details: { fields: poster.saved_changes.keys.excluding("created_at", "updated_at") })
    end
  end
  private_class_method :layout_changed?, :default_layout, :fit_layout, :save!
end

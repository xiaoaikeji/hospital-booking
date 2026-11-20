class PosterSaving
  def self.call(poster, attributes:, file: nil, actor:, request: nil)
    poster.assign_attributes(attributes)
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
      poster.image_width, poster.image_height = image.dimensions
      if poster.new_record?
        poster.qr_size = [ [ poster.image_width, poster.image_height ].min * 24 / 100, 1 ].max
        poster.qr_x = poster.image_width - poster.qr_size - poster.image_width * 6 / 100
        poster.qr_y = poster.image_height - poster.qr_size - poster.image_width * 6 / 100
      end
      normalized = ActionDispatch::Http::UploadedFile.new(tempfile: File.open(image.path, "rb"), filename: file.original_filename, type: file.content_type)
      MediaUpload.attach(normalized, as: :poster_background) do |blob|
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

  def self.save!(poster, actor, request)
    Poster.transaction do
      poster.save!
      Log.record!(category: "poster", action: "poster.save", actor: actor, target: poster, request: request,
        details: { fields: poster.saved_changes.keys.excluding("created_at", "updated_at") })
    end
  end
  private_class_method :save!
end

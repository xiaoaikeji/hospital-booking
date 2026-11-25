# 公共入口：文件 + 用途。存储走现有 Active Storage；直传微信只用 validate!、content_type、filename。
class MediaUpload
  class Invalid < StandardError; end
  class Failed < StandardError; end

  IMAGES = { "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "png" => "image/png", "webp" => "image/webp" }.freeze
  WECHAT_IMAGES = IMAGES.except("webp").freeze
  PURPOSES = {
    user_avatar: { label: "头像", formats: IMAGES, limit: 2.megabytes, temporary_filename: true },
    poster_background: { label: "海报底图", formats: IMAGES, limit: 10.megabytes },
    link_image: { label: "页面配置图片", formats: IMAGES, limit: 10.megabytes },
    hospital_image: { label: "医院图片", formats: IMAGES, limit: 10.megabytes },
    directory_icon: { label: "图标", formats: IMAGES, limit: 10.megabytes },
    doctor_portrait: { label: "医生头像", formats: IMAGES, limit: 2.megabytes },
    menu_image: { label: "图片素材", formats: WECHAT_IMAGES.merge("gif" => "image/gif", "bmp" => "image/bmp"), limit: 10.megabytes },
    reply_card_cover: { label: "卡片封面", formats: WECHAT_IMAGES, limit: 2.megabytes },
    menu_voice: { label: "音频素材", formats: { "mp3" => "audio/mpeg", "amr" => "audio/amr", "wav" => "audio/x-wav" }, limit: 2.megabytes },
    menu_video: { label: "视频素材", formats: { "mp4" => "video/mp4" }, limit: 10.megabytes }
  }.freeze
  KEY_ATTEMPTS = 1000

  def self.attach(file, as:)
    blob = new(file, as: as).create_blob!
    yield blob
  rescue StandardError
    blob.purge if blob && !blob.attachments.exists?
    raise
  end

  def initialize(file, as:)
    @file, @purpose = file, PURPOSES.fetch(as)
  end

  def validate!
    raise Invalid, "请选择#{@purpose[:label]}" unless @file.respond_to?(:tempfile) && @file.respond_to?(:original_filename)
    name = @file.original_filename.to_s
    raise Invalid, "文件名不正确" if name.strip.empty? || name.length > 255
    raise Invalid, "文件是空的" unless @file.size.positive?
    raise Invalid, "#{@purpose[:label]}不能超过 #{@purpose[:limit] / 1.megabyte}MB" if @file.size > @purpose[:limit]
    @file.tempfile.rewind
    detected = Marcel::MimeType.for(@file.tempfile)
    detected = "audio/x-wav" if detected == "audio/wav"
    @extension = File.extname(name).delete_prefix(".").downcase
    if @purpose[:temporary_filename] && [ "", "tmp" ].include?(@extension)
      @extension = @purpose[:formats].key(detected)
    end
    @content_type = @purpose[:formats][@extension]
    raise Invalid, "#{@purpose[:label]}仅支持 #{@purpose[:formats].keys.map(&:upcase).join('、')} 格式" unless @content_type
    declared = @file.content_type.to_s.split(";").first.to_s.strip.downcase
    declared = "image/jpeg" if declared == "image/jpg"
    declared = "audio/x-wav" if declared == "audio/wav"
    unless detected == @content_type && [ "", "application/octet-stream", @content_type ].include?(declared)
      raise Invalid, "文件内容与格式不符"
    end
    self
  ensure
    @file.tempfile.rewind if @file.respond_to?(:tempfile)
  end

  def content_type
    validate! unless @content_type
    @content_type
  end

  # 微信上传也使用相同命名；不在本地另存一份文件。
  def filename
    validate! unless @extension
    @filename ||= object_key(Time.current.to_i)
  end

  def create_blob!
    validate!
    now = Time.current.to_i
    KEY_ATTEMPTS.times do |offset|
      key = object_key(now + offset)
      next if ActiveStorage::Blob.exists?(key: key) || ActiveStorage::Blob.service.exist?(key)
      begin
        blob = ActiveStorage::Blob.transaction(requires_new: true) do
          ActiveStorage::Blob.create!(key: key, filename: @file.original_filename, content_type: content_type,
            byte_size: @file.size, checksum: digest.base64digest)
        end
      rescue ActiveRecord::RecordNotUnique
        next
      end
      begin
        @file.tempfile.rewind
        blob.upload(@file.tempfile, identify: false)
        return blob
      rescue StandardError
        blob.purge
        raise
      end
    end
    raise Failed, "文件未能保存，请稍后重试"
  rescue Invalid, Failed
    raise
  rescue StandardError
    raise Failed, "文件上传失败，请稍后重试"
  end

  private

  def object_key(timestamp) = "#{timestamp}#{digest.hexdigest.first(6)}.#{@extension}"

  def digest
    @digest ||= begin
      @file.tempfile.rewind
      result = Digest::MD5.new
      buffer = "".b
      result << buffer while @file.tempfile.read(1.megabyte, buffer)
      result
    ensure
      @file.tempfile.rewind
    end
  end
end

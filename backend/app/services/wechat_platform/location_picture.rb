module WechatPlatform
  class LocationPicture
    TYPES = { ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png", ".webp" => "image/webp" }.freeze

    def initialize(file)
      raise Error, "请选择不超过 10MB 的补充图片" unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size.between?(1, 10.megabytes)
      @file = file
      @extension = File.extname(file.original_filename.to_s).downcase
      @type = TYPES[@extension]
      unless @type && Marcel::MimeType.for(file.tempfile) == @type && [@type, "application/octet-stream", ""].include?(file.content_type.to_s)
        raise Error, "补充图片仅支持 JPG、PNG 或 WEBP，请核对文件格式"
      end
    end

    def upload!
      digest = Digest::MD5.file(@file.path)
      timestamp = Time.current.to_i
      100.times do |offset|
        key = "#{timestamp + offset}#{digest.hexdigest.first(6)}#{@extension}"
        next if ActiveStorage::Blob.service.exist?(key)
        begin
          blob = ActiveStorage::Blob.transaction(requires_new: true) do
            ActiveStorage::Blob.create!(key: key, filename: @file.original_filename, content_type: @type,
              byte_size: @file.size, checksum: digest.base64digest)
          end
        rescue ActiveRecord::RecordNotUnique
          next
        end
        begin
          @file.rewind
          blob.upload(@file.tempfile, identify: false)
          return blob
        rescue StandardError
          blob.purge
          raise
        end
      end
      raise Error, "图片未能保存，请稍后重试"
    end
  end
end

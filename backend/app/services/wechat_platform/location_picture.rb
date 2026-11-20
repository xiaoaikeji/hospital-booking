module WechatPlatform
  class LocationPicture
    def initialize(file)
      @upload = MediaUpload.new(file, as: :location_picture).validate!
    rescue MediaUpload::Invalid => error
      raise Error, error.message
    end

    def upload! = @upload.create_blob!
  end
end

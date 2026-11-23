require "test_helper"

class MediaUploadTest < ActiveSupport::TestCase
  def file(name: "底图.PNG", type: "image/png", bytes: File.binread(file_fixture("storage.png")))
    temporary = Tempfile.new("media-upload")
    temporary.binmode
    temporary.write(bytes)
    temporary.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: temporary, filename: name, type: type)
  end

  test "names use real content digest and collisions never overwrite rows or stored objects" do
    upload = file(bytes: File.binread(file_fixture("storage.png")) + SecureRandom.bytes(12))
    bytes = upload.read
    upload.rewind
    travel_to Time.zone.at(1_783_295_957) do
      first = MediaUpload.new(upload, as: :link_image).create_blob!
      stray = "1783295958#{Digest::MD5.hexdigest(bytes).first(6)}.png"
      first.service.upload(stray, StringIO.new("existing"))
      second = MediaUpload.new(file(bytes: bytes), as: :poster_background).create_blob!
      assert_equal "1783295957#{Digest::MD5.hexdigest(bytes).first(6)}.png", first.key
      assert_equal "1783295959#{Digest::MD5.hexdigest(bytes).first(6)}.png", second.key
      assert_equal "底图.PNG", first.filename.to_s
      assert_equal bytes, first.download
      assert_equal bytes, second.download
      assert_equal "existing", first.service.download(stray)
    ensure
      first&.service&.delete(stray) if stray
    end
  end

  test "purpose restrictions reject spoofed empty oversized and unsupported files before storage" do
    [ file(bytes: "text"), file(bytes: ""), file(name: "a.gif"), file(type: "audio/mpeg"),
      file(bytes: "x" * (10.megabytes + 1)) ].each do |upload|
      assert_raises(MediaUpload::Invalid) { MediaUpload.new(upload, as: :reply_card_cover).validate! }
    end
    assert_raises(MediaUpload::Invalid) { MediaUpload.new(nil, as: :poster_background).validate! }
    assert_equal "image/png", MediaUpload.new(file(type: "application/octet-stream"), as: :reply_card_cover).validate!.content_type
    assert_match(/\A\d{10}[0-9a-f]{6}\.png\z/, MediaUpload.new(file, as: :reply_card_cover).validate!.filename)
  end

  test "upload and business failures clean up new blobs" do
    service = ActiveStorage::Blob.service
    original = service.method(:upload)
    service.define_singleton_method(:upload) { |*| raise IOError, "private storage details" }
    assert_no_difference "ActiveStorage::Blob.count" do
      error = assert_raises(MediaUpload::Failed) { MediaUpload.new(file, as: :link_image).create_blob! }
      assert_not_includes error.message, "private"
    end
    service.define_singleton_method(:upload, original)
    key = nil
    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(ArgumentError) do
        MediaUpload.attach(file, as: :poster_background) { |blob| key = blob.key; raise ArgumentError }
      end
    end
    assert_not service.exist?(key)
  ensure
    service.define_singleton_method(:upload, original) if original
  end

  test "matches WeChat temporary avatar filenames to the actual image format" do
    [ "wx-avatar", "wx-avatar.tmp" ].each do |name|
      upload = MediaUpload.new(file(name: name, type: "application/octet-stream"), as: :user_avatar)
      assert_equal "image/png", upload.validate!.content_type
      assert_match(/\.png\z/, upload.filename)
    end
    assert_raises(MediaUpload::Invalid) { MediaUpload.new(file(name: "x.tmp", bytes: "text"), as: :user_avatar).validate! }
    assert_raises(MediaUpload::Invalid) { MediaUpload.new(file(name: "x.tmp"), as: :link_image).validate! }
  end
end

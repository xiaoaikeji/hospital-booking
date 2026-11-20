require "test_helper"
require_relative "../support/poster_files"

class PosterSavingTest < ActiveSupport::TestCase
  include PosterFiles
  setup { @actor = Admin.create!(username: "poster_saving", role: "super_admin") }

  test "portrait and EXIF rotation use normalized dimensions for stored background and layout" do
    [ [ 800, 1200, nil ], [ 1200, 800, 6 ] ].each do |width, height, orientation|
      poster = Poster.new
      assert PosterSaving.call(poster, attributes: { name: "义诊" }, file: poster_file(width: width, height: height, orientation: orientation), actor: @actor), poster.errors.full_messages.join
      assert_equal [ 800, 1200, 560, 960, 192 ], poster.attributes.values_at("image_width", "image_height", "qr_x", "qr_y", "qr_size")
      image = MiniMagick::Image.read(poster.background.download)
      assert_equal [ 800, 1200 ], image.dimensions
      assert_includes [ "Undefined", "TopLeft" ], image["%[orientation]"]
      image.destroy!
    end
  end

  test "invalid replacement preserves old background and layout and removes new blob" do
    poster = Poster.new
    assert PosterSaving.call(poster, attributes: { name: "义诊" }, file: poster_file, actor: @actor)
    original = poster.background.blob
    assert_no_difference "ActiveStorage::Blob.count" do
      assert_not PosterSaving.call(poster, attributes: { qr_x: 790 }, file: poster_file, actor: @actor)
    end
    assert_equal original, poster.reload.background.blob
    assert_equal 560, poster.qr_x
  end

  test "audit failure rolls back poster and uploaded background" do
    original = Log.method(:record!)
    Log.define_singleton_method(:record!) { |**| raise ActiveRecord::RecordInvalid, Log.new }
    poster = Poster.new
    assert_no_difference [ "Poster.count", "ActiveStorage::Blob.count" ] do
      assert_not PosterSaving.call(poster, attributes: { name: "义诊" }, file: poster_file, actor: @actor)
    end
    assert_includes poster.errors[:base], "海报未能保存，请稍后重试"
  ensure
    Log.define_singleton_method(:record!, original)
  end
end

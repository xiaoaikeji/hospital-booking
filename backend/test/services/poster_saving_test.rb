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

  test "wide banner default QR placement stays completely inside the image" do
    poster = Poster.new
    assert PosterSaving.call(poster, attributes: { name: "宽横幅" }, file: poster_file(width: 2000, height: 100), actor: @actor), poster.errors.full_messages.join
    assert_equal [ 2000, 100 ], [ poster.image_width, poster.image_height ]
    assert_operator poster.qr_x, :>=, 0
    assert_operator poster.qr_y, :>=, 0
    assert_operator poster.qr_size, :>=, 1
    assert_operator poster.qr_x + poster.qr_size, :<=, poster.image_width
    assert_operator poster.qr_y + poster.qr_size, :<=, poster.image_height
  end

  test "replacing background keeps fitting QR box and clamps or shrinks overflowing QR box" do
    poster = Poster.new
    assert PosterSaving.call(poster, attributes: { name: "义诊海报" }, file: poster_file(width: 1080, height: 1620), actor: @actor)
    assert_equal [ 1080, 1620, 757, 1297, 259 ], poster.attributes.values_at("image_width", "image_height", "qr_x", "qr_y", "qr_size")

    # 1. Existing box overflows 800x800 position -> size preserved, position moved inside.
    unchanged = { name: poster.name, qr_x: poster.qr_x.to_s, qr_y: poster.qr_y.to_s, qr_size: poster.qr_size.to_s }
    assert PosterSaving.call(poster, attributes: unchanged, file: poster_file(width: 800, height: 800), actor: @actor), poster.errors.full_messages.join
    assert_equal [ 800, 800, 541, 541, 259 ], poster.reload.attributes.values_at("image_width", "image_height", "qr_x", "qr_y", "qr_size")

    # 2. Existing box fits inside new 800x800 image -> preserved unchanged.
    assert PosterSaving.call(poster, attributes: { qr_x: 120, qr_y: 160, qr_size: 200 }, actor: @actor)
    fit_unchanged = { qr_x: "120", qr_y: "160", qr_size: "200" }
    assert PosterSaving.call(poster, attributes: fit_unchanged, file: poster_file(width: 800, height: 800), actor: @actor)
    assert_equal [ 800, 800, 120, 160, 200 ], poster.reload.attributes.values_at("image_width", "image_height", "qr_x", "qr_y", "qr_size")

    # 3. Existing box is larger than new image side -> shrunk and moved inside.
    assert PosterSaving.call(poster, attributes: { qr_x: 50, qr_y: 50, qr_size: 700 }, actor: @actor)
    oversized = { qr_x: "50", qr_y: "50", qr_size: "700" }
    assert PosterSaving.call(poster, attributes: oversized, file: poster_file(width: 2000, height: 100), actor: @actor)
    assert_equal [ 2000, 100, 50, 0, 100 ], poster.reload.attributes.values_at("image_width", "image_height", "qr_x", "qr_y", "qr_size")
  end

  test "invalid replacement preserves old background and layout and removes new blob" do
    poster = Poster.new
    assert PosterSaving.call(poster, attributes: { name: "义诊" }, file: poster_file, actor: @actor)
    original = poster.background.blob
    assert_no_difference "ActiveStorage::Blob.count" do
      assert_not PosterSaving.call(poster, attributes: { qr_x: 790 }, file: poster_file(width: 600, height: 600), actor: @actor)
    end
    assert_equal [ 800, 1200 ], [ poster.image_width, poster.image_height ]
    assert_includes poster.errors[:qr_size], "二维码必须完整放在底图内"
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

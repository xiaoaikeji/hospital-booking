module PosterFiles
  def poster_file(width: 800, height: 1200, orientation: nil)
    format = orientation ? "jpg" : "png"
    bytes = MiniMagick::Tool.new("magick") { |c| c.size "#{width}x#{height}"; c.xc "#e9f3ed"; c << "#{format}:-" }
    if orientation
      tiff = "II*\x00".b + [ 8 ].pack("V") + [ 1 ].pack("v") + [ 0x0112, 3, 1, orientation, 0 ].pack("vvVvv") + [ 0 ].pack("V")
      exif = "Exif\x00\x00".b + tiff
      bytes = bytes.byteslice(0, 2) + "\xff\xe1".b + [ exif.bytesize + 2 ].pack("n") + exif + bytes.byteslice(2..)
    end
    file = Tempfile.new([ "poster", ".#{format}" ])
    file.binmode; file.write(bytes); file.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "义诊.#{format}", type: "image/#{format == 'jpg' ? 'jpeg' : format}")
  end
end

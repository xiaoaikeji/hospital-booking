module PageLinkSeeds
  KEY = "page_links_defaults".freeze
  LOCK_ID = 71020014
  ASSETS = Pathname.new(__dir__).join("page_link_images")
  DEFAULTS = [
    { position: "home_banner", name: "预约挂号智慧平台，线上预约，快速便捷", file: "registration-banner.jpg" },
    { position: "profile_menu", name: "预约记录", link_type: "page", url: "/pages/ucenter/appointments", sort_order: 10, file: "registration.png" },
    { position: "profile_menu", name: "意见反馈", link_type: "page", url: "/pages/ucenter/feedback", sort_order: 20, file: "appointment.png" },
    { position: "profile_menu", name: "了解我院", link_type: "page", url: "/pages/ucenter/hospital", sort_order: 30, file: "experts.png" }
  ].freeze

  def self.load!
    Link.with_connection do |db|
      db.execute("SELECT pg_advisory_lock(#{LOCK_ID})")
      begin
        install! unless Setting.exists?(key: KEY)
      ensure
        db.execute("SELECT pg_advisory_unlock(#{LOCK_ID})")
      end
    end
  end

  def self.install!
    records = []
    blobs = []
    unless Link.where(app_id: nil).exists?
      StorageConfiguration.refresh!
      DEFAULTS.each do |entry|
        filename = entry.fetch(:file)
        blob = ASSETS.join(filename).open("rb") do |io|
          file = ActionDispatch::Http::UploadedFile.new(tempfile: io, filename: filename)
          MediaUpload.new(file, as: :link_image).create_blob!
        end
        blobs << blob
        records << Link.new(**entry.except(:file), image: blob)
      end
    end

    Link.transaction(requires_new: true) do
      records.each(&:save!)
      Setting.create!(key: KEY, settings: { initialized: true }, description: "小程序页面配置默认数据已初始化")
    end
  rescue StandardError
    blobs.each { |blob| blob.purge unless blob.attachments.exists? }
    raise
  end
  private_class_method :install!
end

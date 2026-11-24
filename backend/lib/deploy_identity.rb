# frozen_string_literal: true

# Captures the booted release directory and Git revision once at process startup.
module DeployIdentity
  APP_NAME = "booking"
  MUTEX = Mutex.new

  class << self
    def boot!(root: Rails.root)
      MUTEX.synchronize do
        return @identity if @identity

        resolved_path = File.realpath(root.to_s).freeze
        revision_file = File.join(resolved_path, "REVISION")
        revision = File.file?(revision_file) ? File.read(revision_file).strip.freeze : "".freeze
        release = File.basename(resolved_path).freeze

        @identity = {
          app_name: APP_NAME,
          release_path: resolved_path,
          release:,
          revision:,
          sidekiq_tag: "#{APP_NAME}:#{release}".freeze
        }.freeze
      end
    end

    def reset!
      MUTEX.synchronize { @identity = nil }
    end

    def app_name = current[:app_name]
    def release_path = current[:release_path]
    def release = current[:release]
    def revision = current[:revision]
    def sidekiq_tag = current[:sidekiq_tag]

    private

    def current
      @identity || boot!
    end
  end
end

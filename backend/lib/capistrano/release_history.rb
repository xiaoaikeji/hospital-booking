# frozen_string_literal: true

module BookingCapistrano
  module ReleaseHistory
    VERIFIED_MARKER = ".booking-verified"
    TIMESTAMP_PATTERN = /\A[0-9]{14}\z/

    def self.rollback_target(current:, marker_paths:, requested: nil)
      return unless TIMESTAMP_PATTERN.match?(current)

      verified = marker_paths.map { |path| File.basename(File.dirname(path)) }.grep(TIMESTAMP_PATTERN)
      if requested
        requested if requested != current && verified.include?(requested)
      else
        verified.select { |timestamp| timestamp < current }.max
      end
    end
  end
end

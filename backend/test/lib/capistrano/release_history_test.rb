# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/capistrano/release_history"

class BookingCapistranoReleaseHistoryTest < Minitest::Test
  def test_rolls_back_to_the_latest_verified_older_release
    marker_paths = %w[20261124100000 20261124100500 20261124102000 20261124103000].map do |timestamp|
      "/srv/booking/releases/#{timestamp}/.booking-verified"
    end

    assert_equal "20261124100500", BookingCapistrano::ReleaseHistory.rollback_target(
      current: "20261124102000", marker_paths:
    )
    assert_nil BookingCapistrano::ReleaseHistory.rollback_target(
      current: "20261124102000", marker_paths:, requested: "20261124101000"
    )
    assert_equal "20261124100000", BookingCapistrano::ReleaseHistory.rollback_target(
      current: "20261124102000", marker_paths:, requested: "20261124100000"
    )
    assert_nil BookingCapistrano::ReleaseHistory.rollback_target(
      current: "20261124100000", marker_paths:
    )
  end
end

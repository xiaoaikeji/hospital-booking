require "test_helper"

class StoragePipelineTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "local upload analysis image processing and background purge work together" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("storage.png").open,
      filename: "storage.png",
      content_type: "image/png"
    )
    service = blob.service
    key = blob.key
    assert_equal "test", blob.service_name
    assert_equal file_fixture("storage.png").binread, blob.download

    perform_enqueued_jobs(only: ActiveStorage::AnalyzeJob) { blob.analyze_later }
    assert_equal 4, blob.reload.metadata["width"]
    assert_equal 4, blob.metadata["height"]

    variant = blob.variant(resize_to_limit: [ 2, 2 ]).processed
    image = MiniMagick::Image.read(variant.download)
    assert_equal [ 2, 2 ], image.dimensions

    perform_enqueued_jobs { blob.purge_later }
    assert_not service.exist?(key)
    assert_not ActiveStorage::Blob.exists?(blob.id)
  ensure
    blob&.purge if blob&.persisted?
  end
end

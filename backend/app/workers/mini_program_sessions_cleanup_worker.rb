class MiniProgramSessionsCleanupWorker
  include Sidekiq::Job

  def perform
    MiniProgramSession.prune_expired!
  end
end

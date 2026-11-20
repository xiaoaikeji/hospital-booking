# Read-only task monitor

**后台任务** is visible and accessible only to super administrators. It reads a current Sidekiq snapshot: live process metadata, waiting and busy counts by queue, scheduled jobs, retries, final failures, configured recurring tasks and recent failure types. Horizontal bars compare current queue counts; no historical trend is inferred.

`BackgroundJobOverview.fetch` uses Sidekiq's API and the existing `REDIS_SIDEKIQ_URL` connection pool. `ProcessSet.new(false)` disables implicit process cleanup. No retry, clearing, deletion or queue mutations are exposed by routes or UI. Failure projections contain only task class, queue, time, retry count and exception class; arguments, exception messages and backtraces are excluded.

Recurring tasks are discovered from `config/schedule.yml`, and configured queues from `config/sidekiq.yml` plus the schedule. New notification tasks therefore appear automatically. An optional schedule `description` is used as the display label; otherwise known translations or the schedule name are shown. Last enqueue time comes from sidekiq-cron. Last completion and success/failure come from `CronResultRecorder`, registered in Sidekiq's server middleware.

The recorder matches configured worker class, queue and arguments; if multiple definitions match ambiguously it skips recording rather than attributing the result to the wrong definition. It records only completion time, success and exception class in a dedicated Redis hash. It never changes the worker's return value or exception, and a recording outage does not fail the job. A new enqueue does not overwrite the previous completed result. Before the recorder has observed a completion, the page says there is no execution record. Already-running matching workers and their retries count as executions of that configuration; the recorder is not an execution-history ledger.

An empty queue, missing process heartbeats, no completion records and unavailable Redis each have separate states. Snapshot values are approximate because workers update asynchronously. The recent-failure table scans up to 1000 retry entries and the latest 20 final-failure entries, then shows at most 20 ordered by latest failure time; totals cover the full sets.

Restart Sidekiq after deploying so completion recording starts. No monitor migration or schedule edits are required. Web and Sidekiq must use the same task Redis; cache Redis stays separate. Monitoring does not backfill historical completion results.

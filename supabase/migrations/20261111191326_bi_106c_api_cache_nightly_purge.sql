-- Applied to Supabase project via MCP on 20261111191326
-- wave 106c (SOW D313): the response cache keeps one row per page and filter set per data version, and old versions were never removed
-- (2,005 rows, 17 MB on 12-Nov, all for old data versions). Each night at 01:05 IST remove cached answers for an old data version that
-- are more than two days old (a newer version is always recomputed on demand; rows under 24 h old can still be served while they refresh).
select cron.unschedule(jobid) from cron.job where jobname = 'bi-api-cache-purge';
select cron.schedule('bi-api-cache-purge', '35 19 * * *',
  $$delete from bi.api_cache where version is distinct from bi.cache_version() and computed_at < now() - interval '2 days'$$);
-- scheduled-job history: keep 14 days (13,047 older runs were removed once on 12-Nov)
select cron.unschedule(jobid) from cron.job where jobname = 'bi-cron-history-purge';
select cron.schedule('bi-cron-history-purge', '40 19 * * 0',
  $$delete from cron.job_run_details where end_time < now() - interval '14 days'$$);

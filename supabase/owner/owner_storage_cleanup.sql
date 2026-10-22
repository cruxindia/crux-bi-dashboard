-- Crux BI — owner-run storage steps (Supabase SQL editor). Updated 22-Oct-2026 (wave 092). Read docs/STORAGE_AUDIT.md §9–§10 first.
-- Step 1 frees about 17.7 MB (index size after the 22-Oct REINDEX; it grows back to about 23 MB after each full rebuild of
-- bi.point_derived) by removing one index that no query reads. Steps 3–4 remove only rebuildable cache and job-log rows.
-- No business data, audit trail, finance evidence or identity mapping is removed. Step 1 is reversible.

-- Step 0 — checks (continue only if n = nd and dim_dupes = 0)
select (select count(*) from bi.point_derived) n,
       (select count(distinct point_id) from bi.point_derived) nd,
       (select count(*) from (select kind, val from bi.dim group by 1, 2 having count(*) > 1) x) dim_dupes,
       pg_size_pretty(pg_relation_size('bi.point_derived_pkey')) pkey_size,
       (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_before;

-- Step 1 — the primary-key index on the rebuildable Force1 visit cache.
-- bi.point_derived is rebuilt by TRUNCATE + INSERT from bi.v_point (one row per bi.point_store row, whose own primary key
-- guarantees uniqueness). No function reads it by point_id (checked in every function body, 21-Oct-2026).
alter table bi.point_derived drop constraint point_derived_pkey;
-- rollback: alter table bi.point_derived add primary key (point_id);

-- Step 2 — verify
select (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_after;
select public.bi_call('force1', jsonb_build_object('month', to_char(date_trunc('month', current_date), 'YYYY-MM-DD'))) is not null force1_ok,
       public.bi_call('attrition', jsonb_build_object('month', to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM-DD'))) is not null attrition_ok;
select count(*) filter (where passed) passed, count(*) total from bi.test_growth();

-- Step 3 (optional, about 5.9 MB) — response-cache rows written under an older cache version. bi_call never serves them
-- (the version no longer matches) and recomputes a request the next time it is asked for. Rebuildable; nothing else reads them.
select count(*) stale_rows, pg_size_pretty(sum(pg_column_size(v))) stale_payload from bi.api_cache where version < (select max(version) from bi.api_cache);
delete from bi.api_cache where version < (select max(version) from bi.api_cache);
-- then, as separate runs (VACUUM cannot run inside a multi-statement transaction): vacuum (full, analyze) bi.api_cache;  and afterwards  vacuum (analyze) bi.api_cache;
-- (the plain vacuum rebuilds the visibility map that VACUUM FULL leaves empty)

-- Step 4 (optional, under 1 MB) — pg_cron run history older than 14 days (job definitions are untouched).
delete from cron.job_run_details where end_time < now() - interval '14 days';

-- Step 5 — measure again
select (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_final;

-- Keep the storage buckets "ocr" and "bills": the Lumen bill extractor uses them.

-- Optional, Lumen security (decide first — run only if the Lumen page does NOT call these functions with the public key):
-- revoke execute on function public.reset_data() from anon, authenticated;
-- revoke execute on function public.bulk_write_off(text[], text) from anon, authenticated;
-- revoke execute on function public.resolve_failed_upload(text) from anon, authenticated;
-- revoke execute on function public.reconcile_all() from anon, authenticated;

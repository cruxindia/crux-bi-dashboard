-- Crux BI — owner-run storage steps (Supabase SQL editor). Updated 29-Oct-2026 (wave 097). Read docs/STORAGE_AUDIT.md §10–§11 first.
-- Why: the 500 MB database size is an organisation billing quota; above it (billing-period average) Supabase can restrict the
-- organisation (requests return HTTP 402). These steps free about 35 MB without removing business data, audit trail, finance
-- evidence or identity mapping. They do not replace the plan decision (Pro, or an archive design — STORAGE_AUDIT §7).
-- Step 1 is reversible (rollback line given). Run each step on its own.

-- Step 0 — checks (continue only if n = nd and dim_dupes = 0)
select (select count(*) from bi.point_derived) n,
       (select count(distinct point_id) from bi.point_derived) nd,
       (select count(*) from (select kind, val from bi.dim group by 1, 2 having count(*) > 1) x) dim_dupes,
       pg_size_pretty(pg_relation_size('bi.point_derived_pkey')) pkey_size,                          -- 24 MB on 29-Oct
       (select idx_scan from pg_stat_user_indexes where indexrelname = 'point_derived_pkey') pkey_scans,  -- 0 on 29-Oct
       (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_before;

-- Step 1 — the primary-key index on the rebuildable Force1 visit cache (about 24 MB).
-- bi.point_derived is rebuilt by TRUNCATE + INSERT from bi.v_point (one row per bi.point_store row, whose own primary key
-- guarantees uniqueness). No function reads it by point_id (re-checked 29-Oct-2026: 0 index scans since the last statistics reset).
alter table bi.point_derived drop constraint point_derived_pkey;
-- rollback: alter table bi.point_derived add primary key (point_id);

-- Step 2 (optional, about 1.8 MB) — an index on the branch master that no query uses (0 scans on 29-Oct-2026).
drop index if exists bi.client_branch_master_fam_pin;
-- rollback (definition read 29-Oct-2026): create index client_branch_master_fam_pin on bi.client_branch_master using btree (client_family, pincode);

-- Step 3 — verify the dashboard still answers
select (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_after;
select public.bi_call('force1', jsonb_build_object('month', to_char(date_trunc('month', current_date), 'YYYY-MM-DD'))) is not null force1_ok,
       public.bi_call('coverage_status', '{}'::jsonb) is not null coverage_ok;
select count(*) filter (where passed) passed, count(*) total from bi.test_identity();

-- Step 4 (optional, about 10 MB) — response-cache rows written under an older cache version. bi_call never serves them
-- (the version no longer matches) and recomputes a request the next time it is asked for. Rebuildable; nothing else reads them.
select count(*) stale_rows, pg_size_pretty(sum(pg_column_size(v))) stale_payload from bi.api_cache where version < (select max(version) from bi.api_cache);
delete from bi.api_cache where version < (select max(version) from bi.api_cache);
-- then, as separate runs (VACUUM cannot run inside a multi-statement transaction): vacuum (full, analyze) bi.api_cache;  and afterwards  vacuum (analyze) bi.api_cache;

-- Step 5 (optional, under 1 MB) — pg_cron run history older than 14 days (job definitions are untouched).
delete from cron.job_run_details where end_time < now() - interval '14 days';

-- Step 6 — measure again
select (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_final;

-- Keep the storage buckets "ocr" and "bills": the Lumen bill extractor uses them.

-- Optional, Lumen security (decide first — run only if the Lumen page does NOT call these functions with the public key):
-- revoke execute on function public.reset_data() from anon, authenticated;
-- revoke execute on function public.bulk_write_off(text[], text) from anon, authenticated;
-- revoke execute on function public.resolve_failed_upload(text) from anon, authenticated;
-- revoke execute on function public.reconcile_all() from anon, authenticated;

-- Crux BI — owner-run Lumen removal (Supabase SQL editor). Written 29-Oct-2026 (wave 098), on the owner's instruction
-- "you can delete Lumen related things completely if it would save the space ... make sure there is no impact on the dashboard".
--
-- What was already done (migration 098l_lumen_quarantine, reversible, nothing deleted):
--   * the 12 Lumen tables and 19 Lumen functions were moved from the API-exposed "public" schema into "lumen_archive",
--     which no API role (anon / authenticated) can use;
--   * all 39 dashboard endpoints were recomputed afterwards without the cache: every one answered (docs/TEST_REPORT.md, wave 098);
--   * a full backup was taken first and given to the owner: every row of the 12 tables (JSON) and all 7 storage objects
--     (bucket "ocr": 6 files of the Tesseract OCR library and an instruction note; bucket "bills": 1 PDF).
-- Why remove it: Lumen is not used by the dashboard; anon could read and write its tables and call reset_data() through the
-- API, and could download the private bill PDF (storage policy lumen_bills_all granted anon ALL on bucket "bills").
-- Expected saving: about 0.7 MB of database and 11.1 MB of file storage.
-- Run each step on its own.

-- Step 0 — checks (continue only if archived_tables = 12, archived_functions = 19 and outside_dependents = 0)
select (select count(*) from pg_class where relnamespace = 'lumen_archive'::regnamespace and relkind = 'r') archived_tables,
       (select count(*) from pg_proc  where pronamespace = 'lumen_archive'::regnamespace) archived_functions,
       (select count(*) from pg_depend d
          join pg_class c on c.oid = d.objid and d.classid = 'pg_class'::regclass
         where d.refobjid in (select oid from pg_class where relnamespace = 'lumen_archive'::regnamespace)
           and c.relnamespace <> 'lumen_archive'::regnamespace and c.relkind not in ('S', 'i', 't')) outside_dependents,
       (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_before;

-- Step 1 — remove the quarantined Lumen tables and functions
drop schema lumen_archive cascade;

-- Step 2 — remove the storage policy that let anyone read and write the "bills" bucket
drop policy if exists lumen_bills_all on storage.objects;

-- Step 3 — remove the two buckets. Supabase does not allow deleting files with SQL, so use the dashboard:
--   Storage → bucket "ocr"   → ⋯ → Empty bucket, then ⋯ → Delete bucket
--   Storage → bucket "bills" → ⋯ → Empty bucket, then ⋯ → Delete bucket

-- Step 4 — verify the dashboard still answers, and measure
select public.bi_call('meta', '{}'::jsonb) is not null meta_ok,
       public.bi_call('overview', jsonb_build_object('month', to_char(date_trunc('month', current_date), 'YYYY-MM-DD'))) is not null overview_ok,
       (select count(*) from storage.buckets where id in ('ocr', 'bills')) lumen_buckets_left,   -- 0 after Step 3
       (select sum(pg_database_size(datname)) from pg_database) all_databases_bytes_after;

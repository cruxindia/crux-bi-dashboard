-- Applied to Supabase project via MCP on 20261029151419
-- Owner decision 29-Oct-2026 (5.8.4): remove Lumen completely if there is no impact on the dashboard.
-- Step 1 (this migration, reversible): move every Lumen table and function out of the API-exposed public schema
-- into lumen_archive, which no API role can use. Nothing is deleted here. The owner script
-- supabase/owner/owner_lumen_removal.sql removes the schema and the two storage buckets afterwards.
-- Rollback: alter table lumen_archive.<t> set schema public; alter function lumen_archive.<f>(...) set schema public;
do $$
declare n int;
begin
  -- safety: no trigger on a non-Lumen table may use a Lumen trigger function
  select count(*) into n from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal and t.tgfoid in ('public.touch_updated_at()'::regprocedure, 'public._normalize_district_code()'::regprocedure)
     and not (c.relnamespace = 'public'::regnamespace and c.relname in ('branches','crux_identity','district_codes','invoices'));
  if n > 0 then raise exception 'Lumen trigger functions are used by % other trigger(s); stopping', n; end if;
  -- safety: no foreign key from outside Lumen points at a Lumen table
  select count(*) into n from pg_constraint k
   where k.contype = 'f' and k.confrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname in
         ('applicant_lines','branches','checks','clients','crux_identity','district_codes','failed_uploads','field_confidence','ingest_log','invoices','payments','review_progress'))
     and k.conrelid not in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname in
         ('applicant_lines','branches','checks','clients','crux_identity','district_codes','failed_uploads','field_confidence','ingest_log','invoices','payments','review_progress'));
  if n > 0 then raise exception 'outside foreign keys point at Lumen tables (%); stopping', n; end if;
end $$;

create schema if not exists lumen_archive;
comment on schema lumen_archive is 'Lumen (invoice OCR app) quarantined 29-Oct-2026 on owner instruction; not used by the Crux BI dashboard; to be removed by supabase/owner/owner_lumen_removal.sql. Backup taken 29-Oct-2026 (all 12 tables + 7 storage objects).';

alter table public.applicant_lines  set schema lumen_archive;
alter table public.checks           set schema lumen_archive;
alter table public.field_confidence set schema lumen_archive;
alter table public.ingest_log       set schema lumen_archive;
alter table public.failed_uploads   set schema lumen_archive;
alter table public.payments         set schema lumen_archive;
alter table public.invoices         set schema lumen_archive;
alter table public.branches         set schema lumen_archive;
alter table public.clients          set schema lumen_archive;
alter table public.crux_identity    set schema lumen_archive;
alter table public.district_codes   set schema lumen_archive;
alter table public.review_progress  set schema lumen_archive;

alter function public._branch_code_hint(text)              set schema lumen_archive;
alter function public._branch_denoise(text)                set schema lumen_archive;
alter function public._branch_tokens(text)                 set schema lumen_archive;
alter function public._clean_branch_text(text)             set schema lumen_archive;
alter function public._extract_branch_code(text)           set schema lumen_archive;
alter function public._normalize_district_code()           set schema lumen_archive;
alter function public.bulk_write_off(text[], text)         set schema lumen_archive;
alter function public.bump_review_cleared(text, integer)   set schema lumen_archive;
alter function public.learn_client(text)                   set schema lumen_archive;
alter function public.lookup_branch(text, text)            set schema lumen_archive;
alter function public.norm_key(text)                       set schema lumen_archive;
alter function public.reconcile_all()                      set schema lumen_archive;
alter function public.reconcile_invoice(text)              set schema lumen_archive;
alter function public.reset_data()                         set schema lumen_archive;
alter function public.resolve_client(text)                 set schema lumen_archive;
alter function public.resolve_failed_upload(text)          set schema lumen_archive;
alter function public.sync_invoice(jsonb, jsonb, jsonb, jsonb) set schema lumen_archive;
alter function public.sync_invoices_batch(jsonb)           set schema lumen_archive;
alter function public.touch_updated_at()                   set schema lumen_archive;

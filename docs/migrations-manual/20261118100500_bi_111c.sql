-- wave 111c (18-Nov-2026): two remaining same-figure differences found by the first consistency check.
-- (1) Branch-manager view: business as usual in ₹ used this report's rate only (empty on 13/14-Nov) → now the latest known rate, as the
--     BAU model and the tracker do (₹1,02,37,255 vs ₹1,02,67,485 so far). (2) Potential counted administrative offices as client branches
--     (66,082 / 2,749 active vs Units by type 65,968 / 2,708) → same rules as Units by type from the next nightly run.
-- Applied with execute_sql on 18-Nov-2026 (the owner asked for the mismatches to be fixed); recorded in supabase_migrations as 20261118100500.
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
insert into bi.fn_backup (fn, def, wave)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid), 'w111c before' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'bi' and p.proname in ('api_bm', 'potential_refresh');
select pg_temp.patch('bi.api_bm(date,jsonb,jsonb)'::regprocedure, array[
  'o.organic * v_share * coalesce(c.rev / nullif(c.cases, 0), c.rate) ortd',
  'o.organic * v_share * coalesce(c.rev / nullif(c.cases, 0), nullif(c.rate, 0), (select z.rate from bi.zt_row z where z.row_type = ''leaf'' and z.location_id = km.location_id and z.client_code = km.client_code and z.snapshot_date <= v_at and coalesce(z.rate, 0) > 0 order by z.snapshot_date desc limit 1)) /* wave 111c: latest known rate */ ortd'
], array[1]);
select pg_temp.patch('bi.potential_refresh()'::regprocedure, array[
  'where b.status = ''active'' and coalesce(b.verification_status, ''admin_upload'') in (''source_verified'', ''admin_upload'')',
  'where b.status = ''active'' and coalesce(b.verification_status, ''admin_upload'') in (''source_verified'', ''admin_upload'')
       and coalesce(b.source_type, '''') <> ''official_website'' and coalesce(b.branch_type, ''branch'') <> ''office''   -- wave 111c: same units as Units by type'
], array[1]);
delete from bi.api_cache where fn in ('bm');

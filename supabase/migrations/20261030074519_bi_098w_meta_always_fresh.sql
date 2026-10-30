-- Applied to Supabase project via MCP on 20261030074519
-- 30-Oct-2026: after the owner's uploads the dashboard kept saying "Data up to 28.10.2026". Cause: the data-as-of answer (meta) took
-- 15.5 s on the IO-limited instance (two full-table row counts), and the daytime refresh skips anything that took 15 s or more, so it
-- was never refreshed in the day; the pages then asked for the 28-Oct snapshot. Fix:
-- (1) meta reports the two row counts from the planner's statistics (marked as estimates; they are not shown on any page) instead
--     of counting 826k + 238k rows on every refresh;
-- (2) the daytime refresh always takes meta first and never skips it; it now also refreshes any other queued figure that last took
--     under 15 s (landing figures first), still within its 20-second budget every 10 minutes; heavier figures stay at night.
do $do$
declare src text; n int; f text;
begin
  select pg_get_functiondef('bi.api_meta()'::regprocedure) into src;
  if position('rows_are_estimates' in src) = 0 then
    foreach f in array array[$q$'case_rows',(select count(*) from bi.case_store),$q$, $q$'point_rows',(select count(*) from bi.point_store),$q$] loop
      n := (length(src) - length(replace(src, f, ''))) / length(f);
      if n <> 1 then raise exception 'api_meta fragment found % times: %', n, f; end if;
    end loop;
    src := replace(src, $q$'case_rows',(select count(*) from bi.case_store),$q$,
      $q$'case_rows',(select greatest(reltuples, 0)::bigint from pg_class where oid = 'bi.case_store'::regclass),$q$);
    src := replace(src, $q$'point_rows',(select count(*) from bi.point_store),$q$,
      $q$'point_rows',(select greatest(reltuples, 0)::bigint from pg_class where oid = 'bi.point_store'::regclass),'rows_are_estimates',true,$q$);
    execute src;
  end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p where p.proname = 'api_revalidate_light' and p.pronamespace = 'bi'::regnamespace;
  if position('meta is never skipped' in src) = 0 then
    f := $q$              and fn = any (array['meta','overview','daily','insights','business_count','tracker_sheet','zonal','lfl','compare'])
              and coalesce(last_ms, 0) < 15000
            order by requested_at desc limit 40 loop$q$;
    n := (length(src) - length(replace(src, f, ''))) / length(f);
    if n <> 1 then raise exception 'api_revalidate_light selection found % times', n; end if;
    src := replace(src, f, $q$              and (fn = 'meta' or coalesce(last_ms, 0) < 15000)   -- meta is never skipped: it carries the data-as-of date
            order by (fn = 'meta') desc,
                     (fn = any (array['overview','daily','insights','business_count','tracker_sheet','zonal','lfl','compare'])) desc,
                     coalesce(last_ms, 0), requested_at desc
            limit 60 loop$q$);
    execute src;
  end if;
end $do$;

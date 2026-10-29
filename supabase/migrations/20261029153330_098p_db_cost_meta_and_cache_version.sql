-- Applied to Supabase project via MCP on 20261029153330
-- Owner 29-Oct-2026 ("3. 2 - Do it"): database cost work.
-- (1) api_meta (asked on every page load and after every data change): read the stores directly and use the month indexes.
--     Same values (checked 29-Oct-2026): latest case 28-Oct 18:47:27, latest point 28-Oct 13:28:41, 819,949 points, same coverage map.
-- (2) Response-cache version: audit rows that cannot change any figure (an import that only started or was rejected,
--     AI / knowledge-base / job housekeeping) no longer invalidate every cached answer.
do $do$
declare src text; frag text; n int;
  procedure_dummy int;
begin
  select pg_get_functiondef('bi.api_meta()'::regprocedure) into src;
  if position('bi.fact_case' in src) > 0 or position('bi.fact_point' in src) > 0 then
    foreach frag in array array[
      $q$'case_latest_received_ist',(select max(received_at at time zone 'Asia/Kolkata') from bi.fact_case),$q$,
      $q$'case_rows',(select count(*) from bi.fact_case),$q$,
      $q$'point_latest_created_ist',(select max(created_at at time zone 'Asia/Kolkata') from bi.fact_point),$q$,
      $q$'point_rows',(select count(*) from bi.fact_point),$q$,
      $q$from bi.fact_point where recon_unit is not null group by 1$q$] loop
      n := (length(src) - length(replace(src, frag, ''))) / length(frag);
      if n <> 1 then raise exception 'api_meta fragment found % times: %', n, left(frag, 60); end if;
    end loop;
    src := replace(src, $q$'case_latest_received_ist',(select max(received_at at time zone 'Asia/Kolkata') from bi.fact_case),$q$,
                        $q$'case_latest_received_ist',(select max(received_at) from bi.case_store where received_month = (select max(received_month) from bi.case_store)) at time zone 'Asia/Kolkata',$q$);
    src := replace(src, $q$'case_rows',(select count(*) from bi.fact_case),$q$, $q$'case_rows',(select count(*) from bi.case_store),$q$);
    src := replace(src, $q$'point_latest_created_ist',(select max(created_at at time zone 'Asia/Kolkata') from bi.fact_point),$q$,
                        $q$'point_latest_created_ist',(select max(created_at) from bi.point_store where created_month = (select max(created_month) from bi.point_store)) at time zone 'Asia/Kolkata',$q$);
    src := replace(src, $q$'point_rows',(select count(*) from bi.fact_point),$q$, $q$'point_rows',(select count(*) from bi.point_store),$q$);
    src := replace(src, $q$from bi.fact_point where recon_unit is not null group by 1$q$, $q$from bi.point_store where recon_unit is not null group by 1$q$);
    execute src;
  end if;

  select pg_get_functiondef('public.bi_call(text, jsonb)'::regprocedure) into src;
  frag := $q$(select coalesce(max(id),0) from bi.audit_log) * 100000$q$;
  n := (length(src) - length(replace(src, frag, ''))) / length(frag);
  if n = 1 then
    execute replace(src, frag, $q$(select coalesce(max(id),0) from bi.audit_log where action not in ('import_begin', 'import_reject', 'ai_config_change', 'kb_put')
                                     and action not like 'ai\_%' and action not like 'kb\_%' and action not like 'job\_%') * 100000$q$);
  elsif position($q$action not in ('import_begin'$q$ in src) = 0 then
    raise exception 'bi_call version fragment found % times', n;
  end if;
end $do$;

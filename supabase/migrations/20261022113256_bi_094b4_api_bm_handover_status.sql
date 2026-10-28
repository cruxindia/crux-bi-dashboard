-- Applied to Supabase project via MCP on 20261022113256
-- bi_094b4 (22-Oct-2026): hand-over status says when the location × clients had no business around the change (no shift can be measured)
do $do$
declare d text; o text := $o$                       when e.mb_ is null then 'no history before the change'$o$;
        n text := $n$                       when e.mb_ is null then 'no history before the change'
                       when coalesce(e.cb, 0) = 0 and coalesce(e.ca, 0) = 0 then 'no business recorded in the tracker for these location × clients around the change'
                       when coalesce(e.cb, 0) = 0 then 'no business before the change (started after it)'$n$;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'api_bm status fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;

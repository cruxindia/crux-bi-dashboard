-- Applied to Supabase project via MCP on 20261022113515
-- bi_094b5 (22-Oct-2026): organic revenue to date values organic cases at the row's month-to-date revenue per case (as the growth API does), the tracker rate only when there are no cases yet
do $do$
declare d text; o text := $o$o.organic * v_share * coalesce(c.rate, c.rev / nullif(c.cases, 0)) ortd$o$; n text := $n$o.organic * v_share * coalesce(c.rev / nullif(c.cases, 0), c.rate) ortd$n$;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'api_bm rate fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;

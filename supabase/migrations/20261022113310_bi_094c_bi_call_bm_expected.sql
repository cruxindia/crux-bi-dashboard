-- Applied to Supabase project via MCP on 20261022113310
-- bi_094c (22-Oct-2026): bi_call serves the branch-manager panel ('bm') and the expected-revenue measure of growth (business revenue from the Zonal Tracker)
do $do$
declare d text;
        o1 text := $o$      when 'collections' then bi.api_collections(m, f)$o$;
        n1 text := $n$      when 'collections' then bi.api_collections(m, f)
      when 'bm' then bi.api_bm(m, f, coalesce(p_args->'p', '{}'::jsonb))$n$;
        o2 text := $o$      when 'growth' then case when p_args->>'measure' = 'revenue' then bi.api_growth_rev(m, f, coalesce(p_args->'p', '{}'::jsonb)) else bi.api_growth(m, f, coalesce(p_args->'p', '{}'::jsonb)) end$o$;
        n2 text := $n$      when 'growth' then case when p_args->>'measure' = 'revenue' then bi.api_growth_rev(m, f, coalesce(p_args->'p', '{}'::jsonb))
                              when p_args->>'measure' = 'expected' then bi.api_growth(m, f, coalesce(p_args->'p', '{}'::jsonb) || '{"value": "revenue"}'::jsonb)
                              else bi.api_growth(m, f, coalesce(p_args->'p', '{}'::jsonb)) end$n$;
begin
  d := pg_get_functiondef('public.bi_call'::regproc);
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 then raise exception 'bi_call fragment 1 not found exactly once'; end if;
  if (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'bi_call fragment 2 not found exactly once'; end if;
  execute replace(replace(d, o1, n1), o2, n2);
end $do$;

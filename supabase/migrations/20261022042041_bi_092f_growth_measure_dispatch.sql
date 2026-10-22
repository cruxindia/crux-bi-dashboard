-- Applied to Supabase project via MCP on 20261022042041
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  o := $a$when 'growth' then bi.api_growth(m, f, coalesce(p_args->'p', '{}'::jsonb))$a$;
  n := $b$when 'growth' then case when p_args->>'measure' = 'revenue' then bi.api_growth_rev(m, f, coalesce(p_args->'p', '{}'::jsonb)) else bi.api_growth(m, f, coalesce(p_args->'p', '{}'::jsonb)) end$b$;
  if position(o in d) = 0 then raise exception 'bi_call growth line not found'; end if;
  execute replace(d, o, n);
  d := pg_get_functiondef('bi.warm_drill_cache(integer)'::regprocedure);
  o := $a$perform public.bi_call('growth', jsonb_build_object('month', m, 'filters', '{}'::jsonb)); n := n + 1;$a$;
  n := $b$perform public.bi_call('growth', jsonb_build_object('month', m, 'filters', '{}'::jsonb)); n := n + 1;
      perform public.bi_call('growth', jsonb_build_object('month', m, 'filters', '{}'::jsonb, 'measure', 'revenue')); n := n + 1;$b$;
  if position(o in d) = 0 then raise exception 'warm growth line not found'; end if;
  execute replace(d, o, n);
end $do$;


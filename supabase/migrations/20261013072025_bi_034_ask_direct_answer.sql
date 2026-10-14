-- Applied to Supabase project via MCP on 20261013072025
do $do$ declare d text; a text := $x$    if intent='decline' then
      txt := txt || ' Largest decreases: '$x$; begin
 d := pg_get_functiondef('public.bi_ask(text,jsonb,uuid)'::regprocedure);
 if position(a in d)=0 then raise exception 'pattern'; end if;
 d := replace(d, a, $x$    if intent='decline' then
      if (a->>'total_previous') is not null then
        txt := case when (a->>'total_current')::numeric >= (a->>'total_previous')::numeric
                 then format('Not lower: up %s cases vs the same point last month. ', (a->>'total_current')::numeric - (a->>'total_previous')::numeric)
                 else format('Yes, down %s cases (%s%%) vs the same point last month. ', (a->>'total_previous')::numeric - (a->>'total_current')::numeric,
                        round(100*((a->>'total_previous')::numeric - (a->>'total_current')::numeric)/nullif((a->>'total_previous')::numeric,0),1)) end || txt;
      end if;
      txt := txt || ' Largest decreases: '$x$);
 execute d; end $do$;
grant execute on function public.bi_ask(text,jsonb,uuid) to anon, authenticated;

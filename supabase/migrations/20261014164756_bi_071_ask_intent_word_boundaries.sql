-- Applied to Supabase project via MCP on 20261014164756
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_ask(text,jsonb,uuid)'::regprocedure);
  d2 := replace(d, 'when q ~ ''(tat|turnaround|sla|delay)'' then ''tat''', 'when q ~ ''\m(tat|turnaround|sla|delay)'' then ''tat''');
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;

-- Applied to Supabase project via MCP on 20261014165414
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_ask(text,jsonb,uuid)'::regprocedure);
  d2 := replace(d, $o$    txt := format('Case-level Force1 utilisation %s: %s%% (%s of %s tracker cases). Field-level$o$,
                   $n$    txt := format('Case-level Force1 utilisation %s: %s. Field-level$n$);
  d2 := replace(d2, $o$      to_char(m,'Mon YYYY'), round((x->'totals'->>'case_utilisation')::numeric*100,1), x->'totals'->>'force1_cases', x->'totals'->>'tracker_cases',$o$,
                    $n$      to_char(m,'Mon YYYY'), case when x->'totals'->>'case_utilisation' is null then 'not available for this selection (no Case Wise data for it)'
                         else format('%s%% (%s of %s tracker cases)', round((x->'totals'->>'case_utilisation')::numeric*100,1), x->'totals'->>'force1_cases', x->'totals'->>'tracker_cases') end,$n$);
  if d2 = d or position('not available for this selection' in d2) = 0 then raise exception 'anchor'; end if;
  execute d2;
end $$;

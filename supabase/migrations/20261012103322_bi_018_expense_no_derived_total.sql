-- Applied to Supabase project via MCP on 20261012103322

do $$ declare d text; begin
  d := pg_get_functiondef('bi.api_expense(date)'::regprocedure);
  d := replace(d, $a$'level', case when row_type='zone_total' then 'zone' else 'location' end, 'name', name,$a$,
                  $a$'level', case when row_type='zone_total' then 'zone' else 'location' end, 'name', case when row_type='zone_total' then name else coalesce(label, name) end,$a$);
  d := replace(d, $a$l.stakeholder, l.region from t left join$a$, $a$l.stakeholder, l.region, l.label from t left join$a$);
  d := replace(d, $a$  'derived_total_expense', (select sum(expense) from res where row_type='zone_total' or not exists (select 1 from res z2 where z2.row_type='zone_total' and z2.zone_group = res.zone_group)),
$a$, '');
  d := replace(d, $a$per block the larger of total-row value and sum of client rows is used.$a$,
                  $a$per block the larger of total-row value and sum of client rows is used. Zone and location rows overlap, so rows must not be added up; the authoritative all-India figure is source_pan_india_expense (the tracker total row).$a$);
  if position('derived_total_expense' in d) > 0 or position('coalesce(label, name)' in d) = 0 then raise exception 'patch failed'; end if;
  execute d;
end $$;


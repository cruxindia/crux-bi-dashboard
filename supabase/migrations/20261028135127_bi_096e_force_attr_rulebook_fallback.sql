-- Applied to Supabase project via MCP on 20261028135127
-- bi_096e: a Force1 case whose bank branch is not located in the client branch master is attributed to the unit of its rule-book location
-- (area office / branch name / pincode, bi_096a), and only then to the team that processed it
do $do$
declare d text; o1 text; o2 text;
begin
  d := pg_get_functiondef('bi.force_case_daily_refresh()'::regprocedure);
  o1 := $o$case when a.location_id is null then s.recon_unit else coalesce(la.recon_unit, '~outside') end as attr_unit,$o$;
  o2 := $o$  left join bi.location la on la.id = a.location_id and not la.is_rollup$o$;
  if (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 or (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 then raise exception 'fragments'; end if;
  d := replace(d, o1, $n$case when a.location_id is null then coalesce(lc.recon_unit, s.recon_unit) else coalesce(la.recon_unit, '~outside') end as attr_unit,$n$);
  d := replace(d, o2, o2 || chr(10) || $n$  left join bi.location lc on lc.id = s.location_id and not coalesce(lc.is_rollup, false) and lc.recon_unit is not null$n$);
  execute d;
end $do$;

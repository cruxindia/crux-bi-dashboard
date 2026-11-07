-- Applied to Supabase project via MCP on 20261107154313
-- Wave 101b: milestone growth vs current pace used the PAN-India pace for every filter (Gujarat showed −87.8%); now the pace of
-- the same selection.
do $m$
declare d text := pg_get_functiondef('bi.api_targets(date, jsonb, jsonb)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, 'v_ver bigint; v_params jsonb;', 'v_ver bigint; v_params jsonb; v_p0 numeric;');
  if d = o then raise exception 'edit 1'; end if; o := d;
  d := replace(d, '  with t as materialized (',
$q$  select sum(x.pace0) into v_p0 from bi.plan_cells() x
   where (f->>'client_family' is null or x.client_family = f->>'client_family')
     and case when x.location_id is not null then bi.loc_ok(x.location_id, null, f)
              else f - 'client_family' = '{}'::jsonb or (f->>'location_id' is null and f->>'stakeholder' is null and (f->>'zone_group' is null or x.zone_group = f->>'zone_group')) end;
  with t as materialized ($q$);
  if d = o then raise exception 'edit 2'; end if; o := d;
  d := replace(d, '(select round(sum(target) / nullif((select sum(x.pace0) from bi.plan_cells() x), 0) - 1, 4) from t where k = ms)', '(select round(sum(target) / nullif(v_p0, 0) - 1, 4) from t where k = ms)');
  if d = o then raise exception 'edit 3'; end if;
  execute d;
end $m$;

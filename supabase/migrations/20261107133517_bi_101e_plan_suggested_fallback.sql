-- Applied to Supabase project via MCP on 20261107133517
-- Wave 101b: months with neither a saved plan nor a tracker target use the suggested target (default parameters, bi.plan_compute),
-- labelled "suggested target", so a quarter is never compared against a partial plan.
do $m$
declare d text := pg_get_functiondef('bi.api_plan(date, jsonb, jsonb)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, '  _f as materialized (select pf.month, pf.factor from bi.plan_factors(',
'  _sg as materialized (
    select c.month, c.client_family fam, c.location_id, coalesce(c.zone_group, l.zone_group) zone_group, sum(c.target) sg
      from bi.plan_compute(''{}''::jsonb) c left join bi.location l on l.id = c.location_id
     where c.month in (select month from _m)
       and (f->>''client_family'' is null or c.client_family = f->>''client_family'')
       and case when c.location_id is not null then bi.loc_ok(c.location_id, null, f)
                else f - ''client_family'' = ''{}''::jsonb or (f->>''location_id'' is null and f->>''stakeholder'' is null and (f->>''zone_group'' is null or c.zone_group = f->>''zone_group'')) end
     group by 1, 2, 3, 4),
  _f as materialized (select pf.month, pf.factor from bi.plan_factors(');
  if d = o then raise exception 'edit 1'; end if; o := d;
  d := replace(d, 'union select month, fam, location_id from _fc),', 'union select month, fam, location_id from _fc union select month, fam, location_id from _sg),');
  if d = o then raise exception 'edit 2'; end if; o := d;
  d := replace(d, 'coalesce(l.zone_group, pl.zone_group, fc.zone_group) zone_group', 'coalesce(l.zone_group, pl.zone_group, fc.zone_group, sg.zone_group) zone_group');
  if d = o then raise exception 'edit 3'; end if; o := d;
  d := replace(d, 'a.actual, a.tt, a.as_of, pl.plan, fc.fc', 'a.actual, a.tt, a.as_of, pl.plan, fc.fc, sg.sg');
  if d = o then raise exception 'edit 4'; end if; o := d;
  d := replace(d, '            left join bi.location l on l.id = k.location_id),',
'            left join _sg sg on sg.month = k.month and sg.fam = k.fam and sg.location_id is not distinct from k.location_id
            left join bi.location l on l.id = k.location_id),');
  if d = o then raise exception 'edit 5'; end if; o := d;
  d := replace(d, 'case when j.plan is not null then ''plan'' when j.tt is not null then ''tracker target'' end plan_source,
           coalesce(j.plan, j.tt) plan_value,',
'case when j.plan is not null then ''plan'' when j.tt is not null then ''tracker target'' when j.sg is not null then ''suggested target'' end plan_source,
           coalesce(j.plan, j.tt, j.sg) plan_value,');
  if d = o then raise exception 'edit 6'; end if; o := d;
  d := replace(d, '''Plan = the saved plan (Admin → Plan & targets)'' || case when v_ver is null then '' — none saved yet, so the tracker''''s monthly targets are used where they exist'' else '' for its months; months before it use the tracker''''s monthly targets'' end',
'''Plan = the saved plan (Admin → Plan & targets)'' || case when v_ver is null then '' — none saved yet'' else '''' end || ''; months it does not cover use the tracker''''s monthly target, else the suggested target (default parameters: 30% of the opportunity by month 12, growth 2–12% a month after seasonality)''');
  if d = o then raise exception 'edit 7'; end if;
  execute d;
end $m$;

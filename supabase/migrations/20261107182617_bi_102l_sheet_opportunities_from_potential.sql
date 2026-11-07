-- Applied to Supabase project via MCP on 20261107182617
-- wave 102l: new-business opportunities in the target sheet = team x client pairs with potential but no business and no previous target
do $m$
declare d text := pg_get_functiondef('bi.api_target_sheet(date, jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, $a$  opp as (select r2.* from rows2 r2 where r2.cap0 <= 0 and coalesce(r2.prev_rev, 0) <= 0 and (r2.plan_rev > 0 or r2.pot_rev > 0))$a$,
    $a$  opp as (select pt.location_id, l.label location, l.zone_group, pt.fam, coalesce(cl.label, pt.fam) client, pt.pr pot_rev, pt.pcs pot_cases
             from pot pt join bi.location l on l.id = pt.location_id left join bi.client cl on cl.code = pt.fam
            where pt.pr > 0 and pt.fam <> all (v_inact) and not coalesce(l.is_rollup, false)
              and bi.loc_ok(pt.location_id, null, f) and (f->>'client_family' is null or pt.fam = f->>'client_family')
              and not exists (select 1 from rows3 r3 where r3.location_id = pt.location_id and r3.fam = pt.fam))$a$);
  d := replace(d, $a$'opportunities', (select jsonb_build_object('rows', count(*), 'pot_rev', round(sum(pot_rev)), 'plan_rev', round(sum(plan_rev)),$a$,
                  $a$'opportunities', (select jsonb_build_object('rows', count(*), 'pot_rev', round(sum(pot_rev)),$a$);
  if d = o or position('from pot pt join bi.location l' in d) = 0 then raise exception 'anchor not found'; end if;
  execute d;
end $m$;

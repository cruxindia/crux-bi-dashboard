-- Applied to Supabase project via MCP on 20261107172742
-- wave 102d: quarter plan gains actual-to-date per group and a team x client breakdown (variance at every level), and the rule text
do $m$
declare d text := pg_get_functiondef('bi.api_plan(date, jsonb, jsonb)'::regprocedure); o text := d;
begin
  d := replace(d, $a$'plan_this', round(sum(plan_value) filter (where q = 'this')), 'outlook_this'$a$,
                  $a$'plan_this', round(sum(plan_value) filter (where q = 'this')), 'actual_this', round(coalesce(sum(actual) filter (where q = 'this' and month <= v_ref), 0)), 'outlook_this'$a$);
  d := replace(d, $a$    'by_client', (select coalesce($a$, $a$    'by_cell', (select coalesce(jsonb_agg(o order by (o->>'plan_this')::numeric desc nulls last), '[]'::jsonb) from (
        select jsonb_build_object('location_id', location_id, 'location', location, 'zone_group', min(zone_group), 'client_family', fam,
          'plan_this', round(sum(plan_value) filter (where q = 'this')), 'actual_this', round(coalesce(sum(actual) filter (where q = 'this' and month <= v_ref), 0)),
          'outlook_this', round(sum(outlook) filter (where q = 'this')),
          'delta_this', round(sum(outlook) filter (where q = 'this') - sum(plan_value) filter (where q = 'this')),
          'plan_next', round(sum(plan_value) filter (where q = 'next')), 'outlook_next', round(sum(outlook) filter (where q = 'next')),
          'delta_next', round(sum(outlook) filter (where q = 'next') - sum(plan_value) filter (where q = 'next'))) o
        from _r group by location_id, location, fam) z),
    'by_client', (select coalesce($a$);
  d := replace(d, 'growth 2–12% a month after seasonality)', $a$growth 2–12% a month after seasonality, and never below the previous month''s target + 2% except a month with a strong seasonal signal)$a$);
  if position('''by_cell''' in d) = 0 or position('actual_this' in d) = 0 or position('never below the previous' in d) = 0 then raise exception 'api_plan: an anchor was not found'; end if;
  execute d;
end $m$;

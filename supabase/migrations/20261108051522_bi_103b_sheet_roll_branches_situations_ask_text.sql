-- Applied to Supabase project via MCP on 20261108051522
-- wave 103b: viewer roll-ups carry branch counts (each client family once per team) and situation counts; Ask Crux target answer names the situations.
create or replace function bi.sheet_roll(p_rows jsonb, p_by text)
returns jsonb language sql immutable set search_path = bi, public as $f$
  with x as (select e from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) e),
  g as (
    select e->>'zone_group' zone_group,
           case when p_by = 'location' then (e->>'location_id')::int end location_id,
           case when p_by = 'location' then e->>'location' end location,
           count(*) n, count(distinct e->>'location_id') teams,
           count(*) filter (where coalesce((e->>'cap_rev')::numeric, 0) <= 0) dormant,
           count(*) filter (where e->>'note' like '%last month fell%') falling,
           sum((e->>'lm_cases')::numeric) lm_cases, sum((e->>'lm_rev')::numeric) lm_rev, sum((e->>'l3_cases')::numeric) l3_cases, sum((e->>'l3_rev')::numeric) l3_rev,
           sum((e->>'bau_cases')::numeric) bau_cases, sum((e->>'bau_rev')::numeric) bau_rev, sum((e->>'pot_cases')::numeric) pot_cases, sum((e->>'pot_rev')::numeric) pot_rev,
           sum((e->>'prev_rev')::numeric) prev_rev, sum((e->>'prev_cases')::numeric) prev_cases, sum((e->>'plan_rev')::numeric) plan_rev, sum((e->>'base_rev')::numeric) base_rev,
           sum((e->>'cap_rev')::numeric) cap_rev, sum((e->>'catchup_rev')::numeric) catchup_rev, sum((e->>'tgt_rev')::numeric) tgt_rev, sum((e->>'tgt_cases')::numeric) tgt_cases
      from x group by 1, 2, 3),
  b as (  -- branch counts: each client family once per team
    select zone_group, location_id, location, sum(a) br_active, sum(i) br_inactive from (
      select distinct on (e->>'location_id', e->>'client_family') e->>'zone_group' zone_group,
             case when p_by = 'location' then (e->>'location_id')::int end location_id, case when p_by = 'location' then e->>'location' end location,
             coalesce((e->>'br_active')::numeric, 0) a, coalesce((e->>'br_inactive')::numeric, 0) i
        from x order by e->>'location_id', e->>'client_family') d group by 1, 2, 3),
  s as (select zone_group, location_id, location, jsonb_object_agg(sit, n) sits from (
          select e->>'zone_group' zone_group, case when p_by = 'location' then (e->>'location_id')::int end location_id, case when p_by = 'location' then e->>'location' end location,
                 coalesce(e->>'situation', 'n/a') sit, count(*) n from x group by 1, 2, 3, 4) q group by 1, 2, 3)
  select coalesce(jsonb_agg(jsonb_build_object(
           'zone_group', g.zone_group, 'location_id', g.location_id, 'location', g.location,
           'rows', g.n, 'teams', g.teams, 'dormant_rows', g.dormant, 'falling_rows', g.falling,
           'lm_cases', g.lm_cases, 'lm_rev', g.lm_rev, 'l3_cases', round(g.l3_cases, 1), 'l3_rev', g.l3_rev,
           'bau_cases', g.bau_cases, 'bau_rev', g.bau_rev, 'pot_cases', g.pot_cases, 'pot_rev', g.pot_rev,
           'prev_rev', g.prev_rev, 'prev_cases', g.prev_cases, 'plan_rev', g.plan_rev, 'base_rev', g.base_rev, 'cap_rev', g.cap_rev,
           'catchup_rev', g.catchup_rev, 'tgt_rev', g.tgt_rev, 'tgt_cases', g.tgt_cases,
           'br_active', b.br_active, 'br_inactive', b.br_inactive, 'situations', s.sits,
           'vs_last', round(g.tgt_rev / nullif(g.lm_rev, 0) - 1, 4), 'vs_l3', round(g.tgt_rev / nullif(g.l3_rev, 0) - 1, 4)) order by g.tgt_rev desc nulls last), '[]'::jsonb)
    from g left join b on b.zone_group is not distinct from g.zone_group and b.location_id is not distinct from g.location_id
           left join s on s.zone_group is not distinct from g.zone_group and s.location_id is not distinct from g.location_id
$f$;

do $m$ declare d text; o text; begin
  d := pg_get_functiondef('bi.ask_h_target_month(date, jsonb, text)'::regprocedure); o := d;
  d := replace(d, $a$BAU change %s, plan above BAU %s, floors %s, quarter catch-up %s%s.$a$, $a$BAU change %s, situation rules (trend, recovery, activation, plan) %s, floors %s, quarter catch-up %s%s.$a$);
  d := replace(d, $a$; the rest is capped at potential and last month + 50%)'$a$, $a$; the rest is capped at the 1.5× ceiling and potential)'$a$);
  d := replace(d, $a$    'drivers', '[]'::jsonb, 'risks',$a$, $a$    'drivers', (select coalesce(jsonb_agg(k || ': ' || v || ' team × client rows' order by v::int desc), '[]'::jsonb) from jsonb_each_text(coalesce(t->'situations', '{}'::jsonb)) z(k, v)), 'risks',$a$);
  if d = o or position('situation rules (trend' in d) = 0 then raise exception 'ask_h_target_month anchors not found'; end if;
  execute d;
end $m$;

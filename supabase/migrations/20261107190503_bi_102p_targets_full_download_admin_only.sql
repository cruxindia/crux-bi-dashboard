-- Applied to Supabase project via MCP on 20261107190503
-- wave 102p (owner 8-Nov-2026): "only admin should be able to download the forecasted and suggested target for any month, so others see the
-- forecast and all but split and with individual drill down and not full download".
-- Non-admins: target_sheet rows (team x client code) and plan by_cell (team x client) are replaced by zone and team roll-ups; the client rows of
-- ONE team come back when asked with 'team' (served from the same cached figure, filtered) or when the page filter is one team.

create or replace function bi.sheet_roll(p_rows jsonb, p_by text)
returns jsonb language sql immutable set search_path = bi, public as $f$
  select coalesce(jsonb_agg(o order by (o->>'tgt_rev')::numeric desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
             'zone_group', g.zone_group, 'location_id', g.location_id, 'location', g.location,
             'rows', g.n, 'teams', g.teams, 'dormant_rows', g.dormant, 'falling_rows', g.falling,
             'lm_cases', g.lm_cases, 'lm_rev', g.lm_rev, 'l3_cases', round(g.l3_cases, 1), 'l3_rev', g.l3_rev,
             'bau_cases', g.bau_cases, 'bau_rev', g.bau_rev, 'pot_cases', g.pot_cases, 'pot_rev', g.pot_rev,
             'prev_rev', g.prev_rev, 'prev_cases', g.prev_cases, 'plan_rev', g.plan_rev, 'base_rev', g.base_rev, 'cap_rev', g.cap_rev,
             'catchup_rev', g.catchup_rev, 'tgt_rev', g.tgt_rev, 'tgt_cases', g.tgt_cases,
             'vs_last', round(g.tgt_rev / nullif(g.lm_rev, 0) - 1, 4), 'vs_l3', round(g.tgt_rev / nullif(g.l3_rev, 0) - 1, 4)) o
      from (
        select x->>'zone_group' zone_group,
               case when p_by = 'location' then (x->>'location_id')::int end location_id,
               case when p_by = 'location' then x->>'location' end location,
               count(*) n, count(distinct x->>'location_id') teams,
               count(*) filter (where coalesce((x->>'cap_rev')::numeric, 0) <= 0) dormant,
               count(*) filter (where x->>'note' like '%last month fell%') falling,
               sum((x->>'lm_cases')::numeric) lm_cases, sum((x->>'lm_rev')::numeric) lm_rev, sum((x->>'l3_cases')::numeric) l3_cases, sum((x->>'l3_rev')::numeric) l3_rev,
               sum((x->>'bau_cases')::numeric) bau_cases, sum((x->>'bau_rev')::numeric) bau_rev, sum((x->>'pot_cases')::numeric) pot_cases, sum((x->>'pot_rev')::numeric) pot_rev,
               sum((x->>'prev_rev')::numeric) prev_rev, sum((x->>'prev_cases')::numeric) prev_cases, sum((x->>'plan_rev')::numeric) plan_rev, sum((x->>'base_rev')::numeric) base_rev,
               sum((x->>'cap_rev')::numeric) cap_rev, sum((x->>'catchup_rev')::numeric) catchup_rev, sum((x->>'tgt_rev')::numeric) tgt_rev, sum((x->>'tgt_cases')::numeric) tgt_cases
          from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
         group by 1, 2, 3) g) q
$f$;
comment on function bi.sheet_roll(jsonb, text) is 'wave 102p: zone (p_by=zone) or team (p_by=location) roll-up of api_target_sheet rows, for viewers who may not download the team x client sheet';

do $m$
declare d text; o text;
begin
  d := pg_get_functiondef('public.bi_call(text, jsonb)'::regprocedure); o := d;
  d := replace(d, $a$v_admin boolean := bi.admin_ok(p_args->>'admin_key');$a$,
                  $a$v_admin boolean := bi.admin_ok(p_args->>'admin_key');
        v_team int := nullif(p_args->>'team', '')::int;   -- wave 102p: drill-down into one team, served from the page's cached figure$a$);
  d := replace(d, $a$v_key text := md5(p_fn || '|' || coalesce((p_args - 'admin_key')::text,''));$a$,
                  $a$v_key text := md5(p_fn || '|' || coalesce((p_args - 'admin_key' - 'team')::text,''));$a$);
  d := replace(d, $a$values (v_key, p_fn, p_args - 'admin_key')$a$, $a$values (v_key, p_fn, p_args - 'admin_key' - 'team')$a$);
  d := replace(d, $a$values (v_key, r, v_ver, p_fn, p_args - 'admin_key')$a$, $a$values (v_key, r, v_ver, p_fn, p_args - 'admin_key' - 'team')$a$);
  d := replace(d, $a$r := bi.call_compute(p_fn, p_args);$a$, $a$r := bi.call_compute(p_fn, p_args - 'team');$a$);
  d := replace(d, $a$  if p_fn = 'meta' then r := r || jsonb_build_object('role'$a$,
$a$  -- wave 102p: the suggested-target sheet and the plan by team x client are a full download for admins only; others see zone and team
  -- roll-ups and the client rows of one team at a time ('team' or a one-team page filter)
  if p_fn = 'target_sheet' and jsonb_typeof(r->'rows') = 'array' then
    if v_team is not null then
      r := r || jsonb_build_object('team', v_team,
             'rows', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(r->'rows') with ordinality t(x, o) where (x->>'location_id')::int = v_team));
      if jsonb_typeof(r->'opportunities'->'list') = 'array' then
        r := jsonb_set(r, '{opportunities,list}', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(r->'opportunities'->'list') with ordinality t(x, o)
                                                     where x->>'location' = (select l.label from bi.location l where l.id = v_team)));
      end if;
    elsif not v_admin and nullif(f->>'location_id', '') is null then
      r := r || jsonb_build_object('rows_hidden', true, 'by_zone', bi.sheet_roll(r->'rows', 'zone'), 'by_location', bi.sheet_roll(r->'rows', 'location'), 'rows', '[]'::jsonb);
      if jsonb_typeof(r->'opportunities'->'list') = 'array' then
        r := jsonb_set(r, '{opportunities,by_location}', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', zg, 'location', loc, 'rows', n, 'pot_rev', pr, 'pot_cases', pc) order by pr desc), '[]'::jsonb)
                                                           from (select x->>'zone_group' zg, x->>'location' loc, count(*) n, sum((x->>'pot_rev')::numeric) pr, sum((x->>'pot_cases')::numeric) pc
                                                                   from jsonb_array_elements(r->'opportunities'->'list') x group by 1, 2) q));
        r := jsonb_set(r, '{opportunities,list}', '[]'::jsonb);
      end if;
    end if;
  end if;
  if p_fn = 'plan' and jsonb_typeof(r->'by_cell') = 'array' then
    if v_team is not null then
      r := r || jsonb_build_object('team', v_team,
             'by_cell', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(r->'by_cell') with ordinality t(x, o) where (x->>'location_id')::int = v_team));
    elsif not v_admin and nullif(f->>'location_id', '') is null then
      r := (r - 'by_cell') || jsonb_build_object('by_cell_hidden', true);
    end if;
  end if;
  if p_fn = 'meta' then r := r || jsonb_build_object('role'$a$);
  if position('v_team int' in d) = 0 or position($a$p_args - 'admin_key' - 'team')::text$a$ in d) = 0 or position('by_cell_hidden' in d) = 0
     or position($a$call_compute(p_fn, p_args - 'team')$a$ in d) = 0 or position($a$values (v_key, r, v_ver, p_fn, p_args - 'admin_key' - 'team')$a$ in d) = 0 then
    raise exception 'bi_call anchors not found';
  end if;
  execute d;
end $m$;

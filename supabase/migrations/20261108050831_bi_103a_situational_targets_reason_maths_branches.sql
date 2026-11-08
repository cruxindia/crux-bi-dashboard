-- Applied to Supabase project via MCP on 20261108050831
-- wave 103a (owner 8-Nov-2026 10:15 IST): "the planning, calculation and logic for each client in each location would have to be different based on
-- the situation and dynamics"; "add number of branches active and inactive and the reason + calculation (maths) from where this target came".
-- Each team x client code gets a situation (new, growing, stable, declining, collapsed, dormant) and a market modifier (under-penetrated, near
-- potential); the situation picks the rule. Owner guardrails stay: target >= last month's actual + 2% (strong seasonal signal: less the allowed fall),
-- <= 1.5x capacity; dormant pairs keep the old target; no business and no old target -> no target (opportunity).

create or replace function bi.fmt_rs(v numeric) returns text language sql immutable set search_path = bi, public as $f$
  select case when v is null then '–' else
    (case when v < 0 then '−' else '' end) || '₹' ||
    (with s as (select round(abs(v))::bigint::text t)
       select case when length(t) <= 3 then t else regexp_replace(left(t, length(t) - 3), '(\d)(?=(\d{2})+$)', '\1,', 'g') || ',' || right(t, 3) end from s) end
$f$;
comment on function bi.fmt_rs(numeric) is 'wave 103a: exact rupees with Indian digit grouping (₹4,41,535), used in the target maths';

do $m$
declare d text; o text;
begin
  d := pg_get_functiondef('bi.api_target_sheet(date, jsonb, jsonb)'::regprocedure); o := d;
  d := replace(d, $a$v_sig boolean; v_drop numeric; v_ver bigint; v_inact text[]; v_fm numeric; v_fl1 numeric; v_lo date; r jsonb;$a$,
$a$v_sig boolean; v_drop numeric; v_ver bigint; v_inact text[]; v_fm numeric; v_fl1 numeric; v_lo date; r jsonb;
        -- wave 103a: situation rules (defaults; admin can pass other values in p)
        v_col numeric := coalesce((p->>'collapse')::numeric, 0.5);    -- last month below this share of the 3-month average = collapsed
        v_dec numeric := coalesce((p->>'decline')::numeric, 0.9);     -- below this share = declining
        v_gro numeric := coalesce((p->>'grow')::numeric, 1.1);        -- above this share = growing
        v_rec numeric := coalesce((p->>'recover')::numeric, 0.5);     -- collapsed: recover this share of the gap to the average
        v_msh numeric := coalesce((p->>'momentum_share')::numeric, 0.5); v_mmx numeric := coalesce((p->>'momentum_max')::numeric, 0.10);
        v_new numeric := coalesce((p->>'new_growth')::numeric, 0.15); -- started recently: last month + this
        v_act numeric := coalesce((p->>'activation')::numeric, 0.025);-- share of the untapped potential asked for each month (30% a year)
        v_fp numeric;                                                  -- seasonal factor of the previous month (1 = the latest tracker month)$a$);
  d := replace(d, $a$  select pf.factor into v_fl1 from bi.plan_factors(v_l, (v_l + interval '1 month')::date, (v_l + interval '1 month')::date) pf;$a$,
$a$  select pf.factor into v_fl1 from bi.plan_factors(v_l, (v_l + interval '1 month')::date, (v_l + interval '1 month')::date) pf;
  v_fp := case when v_p <= v_l then 1 else (select pf.factor from bi.plan_factors(v_l, v_p, v_p) pf) end;$a$);
  d := replace(d, $a$coalesce(sum(vb.rev) filter (where vb.month between v_c1 and v_c3), 0) / 3.0 r3, coalesce(sum(vb.cases) filter (where vb.month between v_c1 and v_c3), 0) / 3.0 c3,$a$,
$a$coalesce(sum(vb.rev) filter (where vb.month between v_c1 and v_c3), 0) / 3.0 r3, coalesce(sum(vb.cases) filter (where vb.month between v_c1 and v_c3), 0) / 3.0 c3,
           coalesce(sum(vb.rev) filter (where vb.month = v_c1), 0) rm1, coalesce(sum(vb.rev) filter (where vb.month = (v_c1 + interval '1 month')::date), 0) rm2,
           coalesce(sum(vb.rev) filter (where vb.month = v_c3), 0) rm3,$a$);
  d := replace(d, $a$  rows0 as ($a$,
$a$  brc as materialized (select pc.location_id, pc.client_family fam,
                               coalesce(sum(pc.branches) filter (where pc.layer = 'current'), 0) br_a, coalesce(sum(pc.branches) filter (where pc.layer = 'dormant'), 0) br_d,
                               coalesce(sum(pc.branches) filter (where pc.layer in ('never_served', 'never_not_served')), 0) br_n
                          from bi.potential_cell pc where pc.run_id = (select max(run_id) from bi.potential_run) and pc.location_id is not null group by 1, 2),
  rows0 as ($a$);
  d := replace(d, $a$           w.c3 l3_cases, w.r3 l3_rev,$a$, $a$           w.c3 l3_cases, w.r3 l3_rev, w.rm1, w.rm2, w.rm3, coalesce(bc.br_a, 0) br_a, coalesce(bc.br_d, 0) br_d, coalesce(bc.br_n, 0) br_n,$a$);
  d := replace(d, $a$      left join pot pt on pt.location_id = w.location_id and pt.fam = w.fam
      left join fq q$a$, $a$      left join pot pt on pt.location_id = w.location_id and pt.fam = w.fam
      left join brc bc on bc.location_id = w.location_id and bc.fam = w.fam
      left join fq q$a$);
  d := replace(d, $a$  rows1 as (
    select r0.*, greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) cap0,
           greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) * (1 + v_cap) u,
           r0.prev_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end pfl
      from rows0 r0),
  rows1b as (
    select r1.*,
           case when r1.cap0 <= 0 then coalesce(r1.prev_rev, 0)
                else greatest(least(r1.plan_rev, r1.u), r1.lm_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end, r1.bau_rev * (1 + v_gmin)) end base_rev,
           case when r1.cap0 <= 0 then coalesce(r1.prev_rev, 0) else least(r1.plan_rev, r1.u) end plan_c
      from rows1 r1),
  rows2 as (
    select r1.*,
           r1.base_rev + case when r1.cap0 > 0 then least(r1.cu_rev * v_cu, greatest(least(r1.u, case when r1.pot_rev > 0 then greatest(r1.pot_rev, r1.base_rev) else r1.u end) - r1.base_rev, 0)) else 0 end tgt_rev,$a$,
$a$  rows1a as (
    select r0.*, greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) cap0,
           greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) * (1 + v_cap) u,
           r0.lm_rev / nullif(r0.l3_rev, 0) ratio,
           case when greatest(r0.lm_rev, r0.l3_rev, r0.bau_rev) <= 0 then 'dormant'
                when r0.lm_rev > 0 and r0.rm1 <= 0 and r0.rm2 <= 0 then 'new'
                when r0.l3_rev > 0 and r0.lm_rev < v_col * r0.l3_rev then 'collapsed'
                when r0.l3_rev > 0 and r0.lm_rev < v_dec * r0.l3_rev then 'declining'
                when r0.l3_rev > 0 and r0.lm_rev > v_gro * r0.l3_rev then 'growing'
                when r0.lm_rev <= 0 and r0.l3_rev <= 0 then 'bau only'
                else 'stable' end sit,
           case when r0.pot_rev > 0 and r0.br_d + r0.br_n >= greatest(r0.br_a, 1) and r0.pot_rev >= 1.5 * greatest(r0.lm_rev, r0.l3_rev) then 'under-penetrated'
                when r0.pot_rev > 0 and r0.pot_rev < 1.1 * greatest(r0.lm_rev, r0.l3_rev) then 'near potential' end modif,
           r0.lm_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end floor_lm,
           r0.bau_rev * (1 + v_gmin) floor_bau,
           coalesce(v_fm / nullif(v_fp, 0), 1) sr
      from rows0 r0),
  rows1 as (
    select r.*,
           case r.sit when 'new' then r.lm_rev * (1 + v_new) * r.sr
                      when 'growing' then r.lm_rev * (1 + least(v_msh * (r.ratio - 1), v_mmx)) * r.sr
                      when 'stable' then r.lm_rev * r.sr
                      when 'declining' then r.l3_rev
                      when 'collapsed' then r.lm_rev + v_rec * (r.l3_rev - r.lm_rev)
                      when 'bau only' then r.bau_rev else 0 end tv
      from rows1a r),
  rows1c as (
    select r.*, case when r.sit in ('new', 'growing', 'stable') and r.pot_rev > r.tv then v_act * (r.pot_rev - r.tv) else 0 end act,
           case when r.sit in ('new', 'growing', 'stable', 'bau only') then least(r.plan_rev, r.u) end plan_e
      from rows1 r),
  rows1b as (
    select r.*,
           case when r.cap0 <= 0 then coalesce(r.prev_rev, 0) else least(r.u, greatest(r.tv + r.act, coalesce(r.plan_e, 0))) end base_sit,
           case when r.cap0 <= 0 then coalesce(r.prev_rev, 0)
                else greatest(least(r.u, greatest(r.tv + r.act, coalesce(r.plan_e, 0))), r.floor_lm, r.floor_bau) end base_rev,
           case when r.cap0 <= 0 then coalesce(r.prev_rev, 0) else least(r.plan_rev, r.u) end plan_c
      from rows1c r),
  rows1d as (
    select r.*,
           case when r.cap0 > 0 and r.sit in ('new', 'growing', 'stable', 'bau only')
                then greatest(least(r.u, case when r.pot_rev > 0 then greatest(r.pot_rev, r.base_rev) else r.u end) - r.base_rev, 0) else 0 end room,
           sum(case when r.cap0 > 0 then r.cu_rev * v_cu else 0 end) over (partition by r.location_id) cu_team
      from rows1b r),
  rows2 as (
    select r1.*,
           r1.base_rev + case when sum(r1.room) over (partition by r1.location_id) > 0
                              then least(r1.room, r1.cu_team * r1.room / sum(r1.room) over (partition by r1.location_id)) else 0 end tgt_rev,$a$);
  d := replace(d, $a$           case when r1.cap0 <= 0 then 'no business in 3 months: previous target kept, no increase'
                when r1.base_rev = least(r1.plan_rev, r1.u) then case when r1.plan_rev > r1.u then 'plan, capped at ' || round((1 + v_cap) * 100) || '% of what the team does' else 'plan' end
                when r1.base_rev = r1.lm_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end then case when v_sig then 'last month''s actual less the allowed seasonal fall' else 'last month''s actual + ' || round(v_gmin * 100, 1) || '%' end
                else 'BAU + ' || round(v_gmin * 100, 1) || '%' end base_rule$a$, $a$           r1.sit base_rule$a$);
  d := replace(d, $a$           r1.sit base_rule
      from rows1b r1),$a$, $a$           r1.sit base_rule
      from rows1d r1),$a$);
  d := replace(d, $a$      from rows2 r2 where r2.cap0 > 0 or coalesce(r2.prev_rev, 0) > 0),$a$,
$a$      from (select r2.*,
              concat_ws(' ',
                case r2.sit
                  when 'dormant' then 'Dormant: no business in the last 3 months; the old target is kept unchanged (owner rule).'
                  when 'new' then 'New: business started recently (nothing in ' || to_char(v_c1, 'Mon') || ' and ' || to_char(v_c1 + interval '1 month', 'Mon') || '); last month carried forward with +' || round(v_new * 100) || '% momentum.'
                  when 'growing' then 'Growing: last month ' || round(100 * (r2.ratio - 1)) || '% above its 3-month average; the target keeps ' || round(v_msh * 100) || '% of that momentum (at most +' || round(v_mmx * 100) || '%).'
                  when 'stable' then 'Stable: last month within ' || round((1 - v_dec) * 100) || '% of its 3-month average; last month carried to ' || to_char(v_m, 'Mon') || '''s working days and season.'
                  when 'declining' then 'Declining: last month ' || round(100 * (1 - r2.ratio)) || '% below its 3-month average; the target brings it back to that average.'
                  when 'collapsed' then 'Collapsed: last month fell to ' || round(100 * r2.ratio) || '% of the 3-month average; the target recovers ' || round(v_rec * 100) || '% of the gap — find the cause (client, branch or manpower) before sending; no quarter catch-up.'
                  else 'Business-as-usual model only (no tracker business in 4 months but BAU expects some).' end,
                case r2.modif when 'under-penetrated' then 'Under-penetrated: ' || r2.br_a || ' of ' || (r2.br_a + r2.br_d + r2.br_n) || ' client branches active' || case when r2.act > 0 then '; ' || round(v_act * 100, 1) || '% of the untapped potential is added.' else '.' end
                              when 'near potential' then 'Near potential: business is close to what the client''s branches here can give.' end,
                case when r2.cap0 > 0 and r2.base_rev > r2.base_sit + 0.5 then case when r2.base_rev = r2.floor_lm then case when v_sig then 'Floor: last month less the allowed seasonal fall.' else 'Floor applied: last month''s actual + ' || round(v_gmin * 100, 1) || '%.' end else 'Floor applied: BAU + ' || round(v_gmin * 100, 1) || '%.' end end,
                case when r2.cap0 > 0 and r2.plan_e is not null and r2.base_sit = r2.plan_e and r2.plan_e > r2.tv + r2.act + 0.5 then 'The quarter plan share is higher and is used.' end,
                case when r2.cap0 > 0 and r2.base_sit >= r2.u - 0.5 and r2.tv + r2.act > r2.u then 'Ceiling applied: ' || round((1 + v_cap) * 100) || '% of capacity.' end,
                case when r2.tgt_rev > r2.base_rev + 1 then 'Quarter catch-up ' || bi.fmt_rs(r2.tgt_rev - r2.base_rev) || ': the team''s quarter shortfall shared over its growing and stable clients by room to grow.' end) reason,
              case when r2.cap0 <= 0 then 'No business in ' || to_char(v_c1, 'Mon') || '–' || to_char(v_p, 'Mon') || '. Target = previous target ' || bi.fmt_rs(r2.prev_rev)
                     || coalesce(' (' || r2.prev_cases_tracker || ' cases in the tracker)', '') || ', unchanged.'
                   else concat_ws(' ',
                     'Capacity = max(last month ' || bi.fmt_rs(r2.lm_rev) || '; 3-month average ' || bi.fmt_rs(r2.l3_rev) || '; BAU ' || bi.fmt_rs(r2.bau_rev) || ') = ' || bi.fmt_rs(r2.cap0)
                       || '; ceiling = × ' || to_char(1 + v_cap, 'FM0.99') || ' = ' || bi.fmt_rs(r2.u) || '.',
                     'Situation value = ' || case r2.sit
                       when 'new' then bi.fmt_rs(r2.lm_rev) || ' × ' || to_char(1 + v_new, 'FM0.00') || ' × season ' || to_char(r2.sr, 'FM0.000')
                       when 'growing' then bi.fmt_rs(r2.lm_rev) || ' × (1 + min(' || round(v_msh * 100) || '% × ' || round(100 * (r2.ratio - 1)) || '%, ' || round(v_mmx * 100) || '%)) × season ' || to_char(r2.sr, 'FM0.000')
                       when 'stable' then bi.fmt_rs(r2.lm_rev) || ' × season ' || to_char(r2.sr, 'FM0.000')
                       when 'declining' then '3-month average ' || bi.fmt_rs(r2.l3_rev)
                       when 'collapsed' then bi.fmt_rs(r2.lm_rev) || ' + ' || round(v_rec * 100) || '% × (' || bi.fmt_rs(r2.l3_rev) || ' − ' || bi.fmt_rs(r2.lm_rev) || ')'
                       else 'BAU ' || bi.fmt_rs(r2.bau_rev) end || ' = ' || bi.fmt_rs(r2.tv)
                       || case when r2.act > 0 then '; + activation ' || round(v_act * 100, 1) || '% × (potential ' || bi.fmt_rs(r2.pot_rev) || ' − ' || bi.fmt_rs(r2.tv) || ') = ' || bi.fmt_rs(r2.act) else '' end || '.',
                     case when r2.plan_e is not null then 'Plan share = ' || bi.fmt_rs(r2.plan_rev) || case when r2.plan_rev > r2.u then ' (capped at ' || bi.fmt_rs(r2.u) || ')' else '' end || '.' end,
                     'Floors: last month × ' || to_char(case when v_sig then 1 - v_drop else 1 + v_gmin end, 'FM0.000') || ' = ' || bi.fmt_rs(r2.floor_lm) || '; BAU × ' || to_char(1 + v_gmin, 'FM0.00') || ' = ' || bi.fmt_rs(r2.floor_bau) || '.',
                     'Base = max(' || concat_ws('; ', 'situation ' || bi.fmt_rs(least(r2.u, r2.tv + r2.act)), case when r2.plan_e is not null then 'plan ' || bi.fmt_rs(r2.plan_e) end, 'floors ' || bi.fmt_rs(greatest(r2.floor_lm, r2.floor_bau))) || ') = ' || bi.fmt_rs(r2.base_rev) || '.',
                     case when r2.tgt_rev > r2.base_rev + 1 then 'Catch-up + ' || bi.fmt_rs(r2.tgt_rev - r2.base_rev) || ' (room to grow ' || bi.fmt_rs(r2.room) || ') = ' || bi.fmt_rs(r2.tgt_rev) || '.'
                          when r2.sit in ('declining', 'collapsed') then 'No catch-up (' || r2.sit || ').' else 'No catch-up placed.' end) end
                || case when r2.rate > 0 then ' Cases = ' || bi.fmt_rs(r2.tgt_rev) || ' ÷ ' || bi.fmt_rs(r2.rate) || ' a case (' || r2.rate_src || ' rate) = ' || to_char(r2.tgt_rev / r2.rate, 'FM999990.0') || ' → '
                          || case when r2.cap0 <= 0 and r2.prev_cases_tracker is not null then r2.prev_cases_tracker || ' (tracker target cases)' else ceil(r2.tgt_rev / r2.rate)::text end || '.' else ' No rate: cases not computed.' end calc
              from rows2 r2) r2 where r2.cap0 > 0 or coalesce(r2.prev_rev, 0) > 0),$a$);
  d := replace(d, $a$           concat_ws('; ', 'base: ' || r2.base_rule,$a$, $a$           concat_ws('; ', r2.sit || coalesce(' · ' || r2.modif, ''),$a$);
  d := replace(d, $a$             case when r2.cu_rev > 0 and r2.tgt_rev > r2.base_rev + 1 then 'quarter catch-up ' || bi.fmt_inr(r2.tgt_rev - r2.base_rev) end,
             case when r2.cap0 > 0 and r2.cu_rev * v_cu > r2.tgt_rev - r2.base_rev + 1 then 'rest of the catch-up stopped at the ceiling' end,$a$,
$a$             case when r2.tgt_rev > r2.base_rev + 1 then 'quarter catch-up ' || bi.fmt_inr(r2.tgt_rev - r2.base_rev) end,$a$);
  d := replace(d, $a$                  'vs_last', round(tgt_rev / nullif(lm_rev, 0) - 1, 4), 'vs_l3', round(tgt_rev / nullif(l3_rev, 0) - 1, 4), 'note', note)$a$,
$a$                  'vs_last', round(tgt_rev / nullif(lm_rev, 0) - 1, 4), 'vs_l3', round(tgt_rev / nullif(l3_rev, 0) - 1, 4), 'note', note,
                  'situation', sit, 'modifier', modif, 'br_active', br_a, 'br_dormant', br_d, 'br_never', br_n, 'br_inactive', br_d + br_n,
                  'm1_rev', round(rm1), 'm2_rev', round(rm2), 'm3_rev', round(rm3), 'situation_rev', round(least(u, tv + act)), 'activation_rev', round(act), 'room_rev', round(room),
                  'floor_rev', round(greatest(floor_lm, floor_bau)), 'reason', reason, 'calc', calc)$a$);
  d := replace(d, $a$'capped_rows', count(*) filter (where cap0 > 0 and plan_rev > u)) from rows3),$a$,
$a$'capped_rows', count(*) filter (where cap0 > 0 and plan_rev > u), 'cu_team_wanted', round(sum(case when cap0 > 0 then cu_rev * v_cu else 0 end)),
                       'situations', (select jsonb_object_agg(s, n) from (select sit s, count(*) n from rows3 group by 1) z),
                       'situation_rev', (select jsonb_object_agg(s, v) from (select sit s, round(sum(tgt_rev)) v from rows3 group by 1) z),
                       'under_penetrated_rows', count(*) filter (where modif = 'under-penetrated'), 'near_potential_rows', count(*) filter (where modif = 'near potential')) from rows3),$a$);
  d := replace(d, $a$                  jsonb_build_object('label', 'Plan above BAU (capped)', 'value', round(sum(plan_c - bau_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Floors (last month''s actual / BAU + ' || round(v_gmin * 100, 1) || '%)', 'value', round(sum(base_rev - plan_c)), 'kind', 'delta'),$a$,
$a$                  jsonb_build_object('label', 'Situation rules (trend, recovery, activation, plan) vs BAU', 'value', round(sum(base_sit - bau_rev)), 'kind', 'delta'),
                  jsonb_build_object('label', 'Floors (last month''s actual / BAU + ' || round(v_gmin * 100, 1) || '%)', 'value', round(sum(base_rev - base_sit)), 'kind', 'delta'),$a$);
  d := replace(d, $a$    'params', jsonb_build_object('gmin', v_gmin, 'catchup', v_cu, 'cap_over_last', v_cap),$a$,
$a$    'params', jsonb_build_object('gmin', v_gmin, 'catchup', v_cu, 'cap_over_last', v_cap, 'collapse', v_col, 'decline', v_dec, 'grow', v_gro, 'recover', v_rec,
                                 'momentum_share', v_msh, 'momentum_max', v_mmx, 'new_growth', v_new, 'activation', v_act),
    'season_ratio', round(coalesce(v_fm / nullif(v_fp, 0), 1), 4),$a$);
  d := replace(d, $a$'. Capacity = the best of last month, the last 3 months average and BAU; ceiling = capacity + ' || round(v_cap * 100) || '%. Base = the highest of: plan (up to the ceiling); last month''s actual business + ' || round(v_gmin * 100, 1) || '%' || case when v_sig then ' (strong seasonal signal: may fall by up to ' || round(v_drop * 100, 1) || '%)' else '' end
      || '; BAU + ' || round(v_gmin * 100, 1) || '%. A team x client with no business in 3 months keeps its previous target unchanged; one with no business and no previous target gets no target (listed as a new-business opportunity). Quarter catch-up = ' || round(v_cu * 100) || '% of the quarter''s shortfall so far (plan − actual / outlook of its earlier months), shared over the quarter''s remaining months by plan, added only up to the ceiling and potential.$a$,
$a$'. Capacity = the best of last month, the last 3 months average and BAU; ceiling = capacity + ' || round(v_cap * 100) || '%. Each team x client gets a situation and its own rule: new (nothing in the first two of the last three complete months) = last month + ' || round(v_new * 100) || '%; growing (last month above ' || round(v_gro * 100) || '% of its 3-month average) = last month + '
      || round(v_msh * 100) || '% of the momentum, at most +' || round(v_mmx * 100) || '%; stable = last month; declining (below ' || round(v_dec * 100) || '%) = back to the 3-month average; collapsed (below ' || round(v_col * 100) || '%) = last month + ' || round(v_rec * 100) || '% of the gap to the average; new, growing and stable are carried to '
      || to_char(v_m, 'Mon') || '''s working days and season (× ' || to_char(coalesce(v_fm / nullif(v_fp, 0), 1), 'FM0.000') || ') and add ' || round(v_act * 100, 1) || '% of the untapped potential (activation); their quarter-plan share is used when higher. Base = that value up to the ceiling, never below last month''s actual + ' || round(v_gmin * 100, 1) || '%'
      || case when v_sig then ' (strong seasonal signal: may fall by up to ' || round(v_drop * 100, 1) || '%)' else '' end || ' or BAU + ' || round(v_gmin * 100, 1) || '%. Market modifier: under-penetrated = inactive client branches at least as many as active ones and potential at least 1.5× the business; near potential = potential under 1.1× the business. '
      || 'A team x client with no business in 3 months keeps its previous target unchanged; one with no business and no previous target gets no target (listed as a new-business opportunity). Quarter catch-up = ' || round(v_cu * 100) || '% of each team''s quarter shortfall so far (plan − actual / outlook of its earlier months) for this month, shared over that team''s new, growing and stable clients in proportion to their room to grow (up to the ceiling and potential); declining and collapsed clients carry none. Branch counts = the client family''s verified branches in the team (active = a Force1 case in the last 3 months; inactive = dormant + never active).$a$);
  if position('rows1c as' in d) = 0 or position('''situation'', sit' in d) = 0 or position('brc as materialized' in d) = 0 or position('rm1, w.rm2' in d) = 0
     or position('v_fp :=' in d) = 0 or position('Each team x client gets a situation' in d) = 0 or position('''calc'', calc' in d) = 0 or position('Situation rules (trend' in d) = 0
     or position('from rows1d r1)' in d) = 0 or position('r2.sit || coalesce' in d) = 0 or position('cu_team_wanted' in d) = 0 or position('season_ratio' in d) = 0 then
    raise exception 'api_target_sheet: an anchor was not found';
  end if;
  execute d;
end $m$;

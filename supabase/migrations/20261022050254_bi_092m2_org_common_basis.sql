-- Applied to Supabase project via MCP on 20261022050254
create or replace function bi.fin_org_rev(p_months date[], f jsonb default '{}'::jsonb, p_at date default null)
returns table (unit_id int, fam text, month date, org_cases numeric, rpc numeric, rate_ref numeric, rate_t numeric,
               org_billed numeric, org_expected numeric, basis text, ref_months int, ref_from date, ref_to date)
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
#variable_conflict use_column
declare b jsonb := bi.fin_billing_basis(); v_fc date; v_lc date; v_min date; v_max date;
begin
  v_fc := (b->>'first_complete')::date; v_lc := (b->>'last_complete')::date;
  if v_fc is null or v_lc is null or p_months is null then return; end if;
  select least(min(x), v_fc), greatest(max(x), v_lc) into v_min, v_max from unnest(p_months) x;
  return query
  with fx as materialized (select * from bi.fin_rev_facts(v_min, v_max, '{}'::jsonb, p_at)),
       okk as materialized (select distinct x.unit_id, x.fam from bi.fin_rev_facts(v_min, v_max, f, p_at) x where x.unit_ok),
       tm as (select distinct x t from unnest(p_months) x),
       ob as materialized (select * from bi.fin_org_basis(p_months, p_at)),
       tgt as materialized (
         select tm.t, x.unit_id, x.fam, x.organic, x.expected, x.cases
         from tm join fx x on x.month = tm.t join okk on okk.unit_id = x.unit_id and okk.fam = x.fam)
  select g.unit_id, g.fam, g.t, round(g.organic, 1),
         round(case when pb.n >= 2 then pb.rpc when fu.uplift is not null and coalesce(pb.pr, g.expected / nullif(g.cases, 0)) > 0
                    then fu.uplift * coalesce(pb.pr, g.expected / nullif(g.cases, 0)) end, 2),
         round(case when pb.n >= 2 then pb.rate_ref else coalesce(pb.pr, g.expected / nullif(g.cases, 0)) end, 2),
         round(case when g.cases > 0 and g.expected > 0 then g.expected / g.cases end, 2),
         round(g.organic * case when pb.n >= 2 then pb.rpc * coalesce(case when g.cases > 0 and g.expected > 0 then (g.expected / g.cases) / nullif(pb.rate_ref, 0) end, 1)
                                when fu.uplift is not null then fu.uplift * coalesce(case when g.cases > 0 and g.expected > 0 then g.expected / g.cases end, pb.pr) end),
         round(g.organic * coalesce(case when g.cases > 0 and g.expected > 0 then g.expected / g.cases end, case when pb.n >= 2 then pb.rate_ref else pb.pr end)),
         case when g.organic is null then 'no organic cases'
              when pb.n >= 2 then 'pair'
              when fu.uplift is not null and coalesce(pb.pr, g.expected / nullif(g.cases, 0)) > 0 then 'family'
              else 'unavailable' end,
         coalesce(pb.n, fu.n, 0)::int, coalesce(pb.mf, fu.mf), coalesce(pb.ml, fu.ml)
  from tgt g left join ob pb on pb.ref = g.t and pb.unit_id = g.unit_id and pb.fam = g.fam
             left join ob fu on fu.ref = g.t and fu.unit_id is null and fu.fam = g.fam;
end $fn$;

do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth_rev(date,jsonb,jsonb)'::regprocedure);
  o := array[$o0$  ox as materialized (select * from bi.fin_org_rev(v_ms, f, v_at)),$o0$,
$o1$    from spec s join fx x on x.month = s.mon and x.unit_ok
    left join ox o on o.unit_id = x.unit_id and o.fam = x.fam and o.month = x.month$o1$,
$o2$Organic totals cover only pairs with an organic estimate in every month of both periods; the covered share is shown.$o2$];
  n := array[$n0$  ox as materialized (select * from bi.fin_org_rev(v_ms, f, v_at)),
  ob as materialized (select * from bi.fin_org_basis((select array_agg(distinct z.r) from (select min(s.mon) r from spec s where s.side = 'cur' group by s.pid) z), v_at)),$n0$,
$n1$    from spec s join fx x on x.month = s.mon and x.unit_ok
    join (select s2.pid, min(s2.mon) ref from spec s2 where s2.side = 'cur' group by s2.pid) rf on rf.pid = s.pid
    left join ob pb on pb.ref = rf.ref and pb.unit_id = x.unit_id and pb.fam = x.fam
    left join ob fu on fu.ref = rf.ref and fu.unit_id is null and fu.fam = x.fam
    cross join lateral (select case when x.cases > 0 and x.expected > 0 then x.expected / x.cases end rt) rq
    cross join lateral (select round(x.organic * case when pb.n >= 2 then pb.rpc * coalesce(rq.rt / nullif(pb.rate_ref, 0), 1)
                                                      when fu.uplift is not null then fu.uplift * coalesce(rq.rt, pb.pr) end) org_billed,
                               round(x.organic * coalesce(rq.rt, case when pb.n >= 2 then pb.rate_ref else pb.pr end)) org_expected) o$n1$,
$n2$Organic totals cover only pairs with an organic estimate in every month of both periods; the covered share is shown. Both periods of a comparison use the same billed-per-case basis (the last three completely billed months before the current period), so expected organic growth comes from organic case growth and tracker-rate changes only, never from a change of estimate.$n2$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_growth_rev fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;

do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.test_growth_rev(date)'::regprocedure);
  o := $o$  with o as (select * from bi.fin_org_rev(array[bm, (bm - interval '1 month')::date], '{}'::jsonb, (bm + interval '1 month - 1 day')::date)),
       cov as (select unit_id, fam from o group by 1, 2 having count(org_billed) = 2)
  select sum(o.org_billed) filter (where o.month = bm), sum(o.org_billed) filter (where o.month = (bm - interval '1 month')::date) into x, y
  from o join cov using (unit_id, fam);$o$;
  n := $n$  with oa as (select * from bi.fin_org_rev(array[bm], '{}'::jsonb, (bm + interval '1 month - 1 day')::date)),
       fj as (select * from bi.fin_rev_facts((bm - interval '1 month')::date, (bm - interval '1 month')::date, '{}'::jsonb, (bm + interval '1 month - 1 day')::date)
              where month = (bm - interval '1 month')::date),
       j as (select oa.org_billed o1,
                    round(fj.organic * oa.rpc / nullif(oa.rate_ref, 0) * coalesce(case when fj.cases > 0 and fj.expected > 0 then fj.expected / fj.cases end, oa.rate_ref)) o0
             from oa join fj on fj.unit_id = oa.unit_id and fj.fam = oa.fam)
  select sum(o1) filter (where o0 is not null), sum(o0) filter (where o1 is not null) into x, y from j where o1 is not null and o0 is not null;$n$;
  if position(o in d) = 0 then raise exception 'R6 fragment not found'; end if;
  d := replace(d, o, n);
  d := replace(d, $q$'R6 organic expectation (both periods) = Σ organic cases × billed revenue per case over covered pairs'$q$,
               $q$'R6 organic expectation (both periods, one billed-per-case basis) = Σ organic cases × billed per case of the current period''s reference months'$q$);
  execute d;
end $do$;

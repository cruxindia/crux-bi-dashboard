-- Applied to Supabase project via MCP on 20261022041047
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
       refm as materialized (
         select tm.t, g::date m, row_number() over (partition by tm.t order by g desc) rn
         from tm cross join generate_series(v_fc, v_lc, interval '1 month') g where g::date < tm.t),
       ref as materialized (select t, m from refm where rn <= 3),
       cand as materialized (
         select r.t, x.unit_id, x.fam, x.month, x.billed, x.expected, x.cases, x.billed / x.expected ratio
         from ref r join fx x on x.month = r.m
         where x.billed > 0 and x.expected > 0 and x.cases >= 10 and x.fam not in ('(none)')),
       med as (select t, unit_id, fam, percentile_cont(0.5) within group (order by ratio) md from cand group by 1, 2, 3),
       keep as materialized (
         select c.* from cand c join med on med.t = c.t and med.unit_id = c.unit_id and med.fam = c.fam
         where c.ratio between 0.5 * med.md and 2 * med.md),
       pairb as (select t, unit_id, fam, count(*) n, sum(billed) / sum(cases) rpc, sum(expected) / sum(cases) rate_ref, min(month) mf, max(month) ml
                 from keep group by 1, 2, 3),
       famu as (select t, fam, sum(billed) / sum(expected) uplift, count(distinct month) n, min(month) mf, max(month) ml from keep group by 1, 2),
       prate as (select r.t, x.unit_id, x.fam, sum(x.expected) / nullif(sum(x.cases), 0) rr
                 from ref r join fx x on x.month = r.m where x.cases > 0 and x.expected > 0 group by 1, 2, 3),
       tgt as materialized (
         select tm.t, x.unit_id, x.fam, x.organic, x.expected, x.cases
         from tm join fx x on x.month = tm.t join okk on okk.unit_id = x.unit_id and okk.fam = x.fam)
  select g.unit_id, g.fam, g.t, round(g.organic, 1),
         round(case when pb.n >= 2 then pb.rpc when fu.uplift is not null and coalesce(pr.rr, g.expected / nullif(g.cases, 0)) > 0
                    then fu.uplift * coalesce(pr.rr, g.expected / nullif(g.cases, 0)) end, 2),
         round(case when pb.n >= 2 then pb.rate_ref else coalesce(pr.rr, g.expected / nullif(g.cases, 0)) end, 2),
         round(case when g.cases > 0 and g.expected > 0 then g.expected / g.cases end, 2),
         round(g.organic * case when pb.n >= 2 then pb.rpc * coalesce(case when g.cases > 0 and g.expected > 0 then (g.expected / g.cases) / nullif(pb.rate_ref, 0) end, 1)
                                when fu.uplift is not null then fu.uplift * coalesce(case when g.cases > 0 and g.expected > 0 then g.expected / g.cases end, pr.rr) end),
         round(g.organic * coalesce(case when g.cases > 0 and g.expected > 0 then g.expected / g.cases end, case when pb.n >= 2 then pb.rate_ref else pr.rr end)),
         case when g.organic is null then 'no organic cases'
              when pb.n >= 2 then 'pair'
              when fu.uplift is not null and coalesce(pr.rr, g.expected / nullif(g.cases, 0)) > 0 then 'family'
              else 'unavailable' end,
         coalesce(pb.n, fu.n, 0)::int, coalesce(pb.mf, fu.mf), coalesce(pb.ml, fu.ml)
  from tgt g left join pairb pb on pb.t = g.t and pb.unit_id = g.unit_id and pb.fam = g.fam
             left join famu fu on fu.t = g.t and fu.fam = g.fam
             left join prate pr on pr.t = g.t and pr.unit_id = g.unit_id and pr.fam = g.fam;
end $fn$;


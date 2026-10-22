-- Applied to Supabase project via MCP on 20261022050202
create or replace function bi.fin_org_basis(p_refs date[], p_at date default null)
returns table (ref date, unit_id int, fam text, n int, rpc numeric, rate_ref numeric, pr numeric, uplift numeric, mf date, ml date)
language plpgsql stable security definer set search_path to 'bi', 'public' as $fn$
#variable_conflict use_column
declare b jsonb := bi.fin_billing_basis(); v_fc date; v_lc date;
begin
  v_fc := (b->>'first_complete')::date; v_lc := (b->>'last_complete')::date;
  if v_fc is null or v_lc is null or p_refs is null then return; end if;
  return query
  with fx as materialized (select * from bi.fin_rev_facts(v_fc, v_lc, '{}'::jsonb, p_at)),
       tm as (select distinct x t from unnest(p_refs) x),
       refm as materialized (
         select tm.t, g::date m, row_number() over (partition by tm.t order by g desc) rn
         from tm cross join generate_series(v_fc, v_lc, interval '1 month') g where g::date < tm.t),
       rw as materialized (select t, m from refm where rn <= 3),
       cand as materialized (
         select r.t, x.unit_id, x.fam, x.month, x.billed, x.expected, x.cases, x.billed / x.expected ratio
         from rw r join fx x on x.month = r.m
         where x.billed > 0 and x.expected > 0 and x.cases >= 10 and x.fam not in ('(none)')),
       med as (select t, unit_id, fam, percentile_cont(0.5) within group (order by ratio) md from cand group by 1, 2, 3),
       keep as materialized (
         select c.* from cand c join med on med.t = c.t and med.unit_id = c.unit_id and med.fam = c.fam
         where c.ratio between 0.5 * med.md and 2 * med.md),
       pairb as (select t, unit_id, fam, count(*) n, sum(billed) / sum(cases) rpc, sum(expected) / sum(cases) rate_ref, min(month) mf, max(month) ml
                 from keep group by 1, 2, 3),
       famu as (select t, fam, sum(billed) / sum(expected) uplift, count(distinct month) n, min(month) mf, max(month) ml from keep group by 1, 2),
       prate as (select r.t, x.unit_id, x.fam, sum(x.expected) / nullif(sum(x.cases), 0) rr
                 from rw r join fx x on x.month = r.m where x.cases > 0 and x.expected > 0 group by 1, 2, 3)
  select coalesce(pb.t, pr.t), coalesce(pb.unit_id, pr.unit_id), coalesce(pb.fam, pr.fam), pb.n::int, pb.rpc, pb.rate_ref, pr.rr, null::numeric, pb.mf, pb.ml
  from pairb pb full join prate pr on pr.t = pb.t and pr.unit_id = pb.unit_id and pr.fam = pb.fam
  union all
  select fu.t, null::int, fu.fam, fu.n::int, null::numeric, null::numeric, null::numeric, fu.uplift, fu.mf, fu.ml from famu fu;
end $fn$;
comment on function bi.fin_org_basis(date[], date) is 'Billed-per-case basis for revenue organic: per reference month, pair rows (unit_id set: n usable months, rpc, rate_ref, pair tracker rate pr) and family rows (unit_id null: uplift = billed ÷ expected). Window = last ≤3 completely billed months before the reference month; outlier months (billed ÷ expected outside 0.5–2× the pair median) left out.';

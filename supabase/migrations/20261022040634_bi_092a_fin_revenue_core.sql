-- Applied to Supabase project via MCP on 20261022040634
-- bi_092a (22-Oct-2026): revenue-first analytics — finance facts.
-- * Billing completeness rule and billing units (location, or the whole zone where invoices do not name the city).
-- * Unit × client family × month facts: actual invoiced revenue (identified invoices, ex-GST basic), expected minimum revenue
--   (Zonal Tracker), cases, organic cases, settlement and ledger GST/TDS amounts.
-- * Organic revenue: organic cases × historical invoiced revenue per case (pooled over the last complete billing months),
--   adjusted for the month's tracker rate, with a family-level fallback and a back-test.
-- Read-only for business data; adds columns and settings only.

insert into bi.fin_config (key, value, note) values
  ('billing_complete_days', '30', 'An invoice month counts as completely billed once the outstanding snapshot is at least this many days after the month end. Evidence 22-Oct-2026: 15 days after Sep-2026 only 94% of expected revenue was invoiced (Kolhapur 11%, Hyderabad 38%); 45 days after Aug-2026, 104%.'),
  ('zone_billing_share', '0.10', 'If at least this share of a zone''s invoice value (complete billing months) is mapped only to the zone (invoices that do not name the city), the whole zone is one billing unit for revenue analysis.')
on conflict (key) do nothing;

alter table bi.fin_os_agg add column if not exists gross numeric not null default 0;
alter table bi.fin_os_agg add column if not exists tds numeric not null default 0;
alter table bi.fin_inv_month add column if not exists gross_l numeric not null default 0;
alter table bi.fin_inv_month add column if not exists tds_l numeric not null default 0;
alter table bi.fin_inv_month add column if not exists net_l numeric not null default 0;
comment on column bi.fin_inv_month.gross_l is 'Gross (basic + GST) of the invoices of this group that are still in the ledger snapshot; invoices known only from receipts carry no GST/TDS split';
comment on column bi.fin_inv_month.tds_l is 'TDS recorded in the ledger snapshot for those invoices';

create or replace function bi.fin_billing_basis() returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $$
  with os as (select id, as_of, file_name from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1),
       co as (select min(coalesce(period_from, as_of)) pfrom, max(as_of) thru, (array_agg(file_name order by as_of desc))[1] fname
              from bi.fin_upload where kind = 'collection' and status = 'committed'),
       cfg as (select coalesce((select (value #>> '{}')::int from bi.fin_config where key = 'billing_complete_days'), 30) d),
       b as (select os.id os_upload, os.as_of, os.file_name os_file, co.pfrom, co.thru, co.fname co_file, cfg.d,
                    (date_trunc('month', co.pfrom) - interval '1 month')::date first_complete
             from os, co, cfg)
  select jsonb_build_object('outstanding_upload', b.os_upload, 'as_of', b.as_of, 'outstanding_file', b.os_file,
           'receipts_from', b.pfrom, 'receipts_through', b.thru, 'collection_file', b.co_file, 'complete_days', b.d,
           'first_complete', b.first_complete,
           'last_complete', (select max(g::date) from generate_series(b.first_complete, date_trunc('month', b.as_of), interval '1 month') g
                              where (g + interval '1 month' - interval '1 day')::date + b.d <= b.as_of),
           'rule', 'An invoice month is completely billed from ' || to_char(b.first_complete, 'Mon-YYYY') ||
                   ' (receipts start ' || to_char(b.pfrom, 'DD-Mon-YYYY') || ', so earlier invoices that were already paid are missing) and once the outstanding snapshot is at least ' ||
                   b.d || ' days after the month end (snapshot ' || to_char(b.as_of, 'DD-Mon-YYYY') || ').')
  from b $$;

create or replace function bi.fin_month_status(p_month date, b jsonb) returns text language sql immutable as $$
  select case when b->>'first_complete' is null then 'none'
              when p_month < (b->>'first_complete')::date then 'incomplete'
              when p_month <= (b->>'last_complete')::date then 'complete'
              when p_month <= date_trunc('month', (b->>'as_of')::date) then 'partial'
              else 'none' end $$;

create or replace function bi.fin_unit_map()
returns table (location_id int, unit_id int, unit_label text, members int, zone_level boolean, basis text, is_member boolean)
language sql stable security definer set search_path to 'bi', 'public' as $$
  with b as (select (j->>'first_complete')::date fc, (j->>'last_complete')::date lc from (select bi.fin_billing_basis() j) x),
       share as (select coalesce((select (value #>> '{}')::numeric from bi.fin_config where key = 'zone_billing_share'), 0.10) s),
       z as (select r.id rid, r.label rlabel, r.rollup_zone zg,
                    coalesce((select sum(i.basic) from bi.fin_inv_month i, b where i.location_id = r.id and i.inv_n > 0 and i.inv_month between b.fc and b.lc), 0) zb,
                    coalesce((select sum(i.basic) from bi.fin_inv_month i join bi.location m on m.id = i.location_id, b
                              where (m.id = r.id or (not coalesce(m.is_rollup, false) and m.zone_group = r.rollup_zone))
                                and i.inv_n > 0 and i.inv_month between b.fc and b.lc), 0) tb
             from bi.location r where r.is_rollup),
       zu as (select z.* from z, share where z.tb > 0 and z.zb / z.tb >= share.s),
       m as (select l.id location_id, coalesce(zu.rid, l.id) unit_id, zu.rid is not null zl
             from bi.location l left join zu on zu.zg = l.zone_group
             where not coalesce(l.is_rollup, false)),
       cnt as (select m.unit_id, count(*) n from m group by 1)
  select m.location_id, m.unit_id,
         case when m.zl then u.label || ' — all ' || cnt.n || ' locations (invoices do not name the city)' else u.label end,
         cnt.n::int, m.zl,
         case when m.zl then 'zone billing: ' || round(100 * zu.zb / zu.tb) || '% of the zone''s invoice value in complete months is not attributed to a city' else 'location' end,
         true
  from m join bi.location u on u.id = m.unit_id join cnt on cnt.unit_id = m.unit_id left join zu on zu.rid = m.unit_id
  union all
  select zu.rid, zu.rid, zu.rlabel || ' — all ' || cnt.n || ' locations (invoices do not name the city)', cnt.n::int, true,
         'zone billing: ' || round(100 * zu.zb / zu.tb) || '% of the zone''s invoice value in complete months is not attributed to a city', false
  from zu join cnt on cnt.unit_id = zu.rid
  union all
  select r.id, r.id, r.label || ' (office without a dashboard location)', 0, true, 'zone-level invoices only', false
  from bi.location r where r.is_rollup and not exists (select 1 from zu where zu.rid = r.id)
  union all
  select 0, 0, 'Location not identified', 0, false, 'invoice series and location label not mapped', false $$;

create or replace function bi.fin_rev_facts(p_from date, p_to date, f jsonb default '{}'::jsonb, p_at date default null)
returns table (unit_id int, fam text, month date, billed numeric, inv_n int, settled numeric, open_b numeric, collected numeric,
               gross_l numeric, tds_l numeric, net_l numeric, expected numeric, cases numeric, organic numeric, unit_ok boolean, unit_split boolean)
language sql stable security definer set search_path to 'bi', 'public' as $$
  with um as materialized (select * from bi.fin_unit_map()),
       uok as materialized (
         select u.unit_id,
                bool_and(case when not u.is_member then bi.fin_loc_ok(u.location_id, coalesce(f, '{}'::jsonb))
                              else bi.loc_ok(u.location_id, l.recon_unit, coalesce(f, '{}'::jsonb), coalesce(p_at, p_to)) end) all_ok,
                bool_or(case when not u.is_member then bi.fin_loc_ok(u.location_id, coalesce(f, '{}'::jsonb))
                             else bi.loc_ok(u.location_id, l.recon_unit, coalesce(f, '{}'::jsonb), coalesce(p_at, p_to)) end) any_ok
         from um u left join bi.location l on l.id = u.location_id
         where u.is_member or u.members = 0 group by 1),
       fi as (select um.unit_id, i.family fam, i.inv_month mo, sum(i.basic) b, sum(i.inv_n)::int n, sum(i.settled_basic) s, sum(i.open_basic) o,
                     sum(i.collected) c, sum(i.gross_l) g, sum(i.tds_l) t, sum(i.net_l) nl
              from bi.fin_inv_month i join um on um.location_id = i.location_id
              where i.inv_n > 0 and i.inv_month between p_from and p_to group by 1, 2, 3),
       tr as (select um.unit_id, coalesce(c.family, v.client_code) fam, v.month mo, sum(v.revenue) e, sum(v.cases) cs
              from bi.v_month_business v join um on um.location_id = v.location_id left join bi.client c on c.code = v.client_code
              where v.month between p_from and p_to group by 1, 2, 3),
       og as (select um.unit_id, coalesce(c.family, o.client_code) fam, o.month mo, sum(o.organic) org
              from bi.organic_store o join um on um.location_id = o.location_id left join bi.client c on c.code = o.client_code
              where o.month between p_from and p_to group by 1, 2, 3),
       k as (select unit_id, fam, mo from fi union select unit_id, fam, mo from tr union select unit_id, fam, mo from og)
  select k.unit_id, k.fam, k.mo, fi.b, fi.n, fi.s, fi.o, fi.c, fi.g, fi.t, fi.nl, tr.e, tr.cs, og.org,
         coalesce(uok.all_ok, false) and (f->>'client_family' is null or k.fam = f->>'client_family'),
         coalesce(uok.any_ok and not uok.all_ok, false) and (f->>'client_family' is null or k.fam = f->>'client_family')
  from k left join fi on fi.unit_id = k.unit_id and fi.fam = k.fam and fi.mo = k.mo
         left join tr on tr.unit_id = k.unit_id and tr.fam = k.fam and tr.mo = k.mo
         left join og on og.unit_id = k.unit_id and og.fam = k.fam and og.mo = k.mo
         left join uok on uok.unit_id = k.unit_id $$;

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
  with fx as materialized (select * from bi.fin_rev_facts(v_fc, v_max, '{}'::jsonb, p_at)),
       okk as materialized (select distinct x.unit_id, x.fam from bi.fin_rev_facts(v_fc, v_max, f, p_at) x where x.unit_ok),
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


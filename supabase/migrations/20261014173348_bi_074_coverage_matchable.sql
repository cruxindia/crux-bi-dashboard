-- Applied to Supabase project via MCP on 20261014173348
-- bi_074: website-listed branches (no branch codes) can't be matched to Force1 cases, so they are no longer
-- counted as "never activated"; totals expose the matchable denominator used for coverage.
create or replace function bi.api_branch_coverage(f jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
with locs as (select l2.id, l2.label from bi.location l2 where bi.loc_ok(l2.id, l2.recon_unit, f)),
fams as (select r.family from bi.client_family_research r where bi.fam_ok(r.family, f) union select c2.family from bi.client c2 where bi.fam_ok(c2.family, f)),
cut as (select (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date c),
x as (
  select v.*, a.last_m, a.first_m, a.n, a.n3, l.label location
  from bi.branch_cov_mv v
  left join bi.branch_activity a on a.fam = v.fam and a.code_norm = v.code_norm and not v.website
  left join bi.location l on l.id = v.location_id
  where (v.location_id is null and coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb or v.location_id in (select id from locs))
    and v.fam in (select family from fams)),
ver as (select * from x where status = 'active' and vs in ('source_verified', 'admin_upload')),
peer as (select fam, location_id, percentile_cont(0.5) within group (order by n3 / 3.0) med, count(*) peers
         from ver where n3 > 0 and location_id is not null group by 1, 2 having count(*) >= 5),
bc as (select v.fam client_code, count(*) verified_active, count(*) filter (where v.last_m >= (select c from cut)) active_with_crux_6m,
              count(*) filter (where v.n is not null) ever_with_crux, count(*) filter (where v.n is null and not v.website) never_activated,
              count(*) filter (where v.website) website_listed, bool_or(v.website) website_source
       from ver v group by 1),
cl as (select fam, count(*) filter (where status <> 'active') closed, count(*) filter (where status = 'active' and vs = 'status_uncertain') uncertain from x group by 1),
lv as (select r.family fam, max(r.last_verified_at) last_verified from bi.client_family_research r group by 1),
na as (select z.branch_uid, z.fam, p.med from ver z left join peer p on p.fam = z.fam and p.location_id = z.location_id
       where z.n is null and z.location_id is not null and not z.website order by p.med desc nulls last, z.fam limit 500)
select jsonb_build_object(
  'master_rows', (select count(*) from x),
  'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_code', bc.client_code, 'verified_active', verified_active, 'closed_or_ineligible', coalesce(cl.closed, 0),
       'status_uncertain', coalesce(cl.uncertain, 0),
       'active_with_crux_6m', case when website_source then null else active_with_crux_6m end,
       'ever_with_crux', case when website_source then null else ever_with_crux end,
       'never_activated', case when website_source then null else never_activated end,
       'coverage_6m', case when website_source then null else round(active_with_crux_6m::numeric / nullif(verified_active, 0), 4) end,
       'matching', case when website_source then 'not matchable by code (website list)' else 'branch code' end,
       'last_verified', to_char(lv.last_verified, 'YYYY-MM-DD')) order by verified_active desc), '[]')
     from bc left join cl on cl.fam = bc.client_code left join lv on lv.fam = bc.client_code),
  'totals', (select jsonb_build_object('verified_active', sum(verified_active), 'verified_matchable', sum(verified_active - website_listed),
       'website_listed', sum(website_listed), 'active_with_crux_6m', sum(active_with_crux_6m), 'never_activated', sum(never_activated),
       'coverage_6m', round(sum(active_with_crux_6m)::numeric / nullif(sum(verified_active - website_listed), 0), 4),
       'clients_with_list', count(*)) from bc),
  'by_location', (select coalesce(jsonb_agg(jsonb_build_object('location', location, 'verified_active', n, 'verified_matchable', nm, 'active_with_crux_6m', a, 'coverage_6m', round(a::numeric / nullif(nm, 0), 4)) order by n desc), '[]')
     from (select coalesce(location, '(territory not mapped to a unit)') location, count(*) n, count(*) filter (where last_m >= (select c from cut)) a,
                  count(*) filter (where not website) nm from ver group by 1) q),
  'opportunity', (select jsonb_build_object('never_activated_with_peer_benchmark', count(*), 'indicative_cases_per_month', round(sum(p.med)::numeric, 0))
     from ver v join peer p on p.fam = v.fam and p.location_id = v.location_id where v.n is null and not v.website),
  'never_activated', (select coalesce(jsonb_agg(jsonb_build_object('client', na.fam, 'branch_code', b.branch_code, 'ifsc', b.ifsc, 'branch', b.branch_name, 'type', b.branch_type,
       'city', coalesce(b.centre, b.city), 'district', b.district, 'state', b.state, 'location', l.label, 'opened_on', b.opened_on, 'verified_on', b.verified_on,
       'confidence', b.confidence, 'peer_cases_per_month', round(na.med::numeric, 1)) order by na.med desc nulls last, na.fam, b.state, b.district), '[]')
     from na join bi.client_branch_master b on b.branch_uid = na.branch_uid left join bi.location l on l.id = b.location_id),
  'dormant_verified', (select coalesce(jsonb_agg(jsonb_build_object('client', z.fam, 'branch_code', b.branch_code, 'branch', b.branch_name, 'location', z.location, 'last_case_month', z.last_m, 'cases_total', z.n) order by z.last_m), '[]')
     from (select * from ver where n is not null and last_m < (select c from cut) order by last_m limit 500) z join bi.client_branch_master b on b.client_code = z.client_code and b.branch_code = z.branch_code),
  'force_branches_not_in_master', (select count(*) from bi.branch_activity s where s.fam in (select distinct fam from ver where not website)
     and not exists (select 1 from bi.branch_cov_mv m2 where m2.fam = s.fam and m2.code_norm = s.code_norm)),
  'method', 'Verified universe = active, source-verified branches and processing centres in the client branch master (administrative offices excluded): bank branches from the RBI IFSC directory, refreshed monthly; other lenders from their official branch locators. Active with Crux = a Force1 case in the last 6 months, matched by the bank''s branch code (leading zeros ignored). Coverage = active with Crux ÷ verified branches that can be matched by code. Website-sourced lists have no branch codes, so they are counted in the universe but excluded from coverage, never-activated and opportunity figures. Never activated = verified, code-matchable branch with no Force1 case since Jan-2026 (Force1 history start). Indicative activation level = median monthly Force1 cases of active branches of the same client in the same Crux location (only where at least 5 such branches exist); an indication, not a forecast. Branches no longer listed by the source are kept as "status uncertain" until reviewed and excluded from coverage.')
$function$;

insert into bi.audit_log(actor, action, entity, detail) values ('migration bi_074', 'definition_change', 'branch_coverage', '{"note":"website-listed branches excluded from never-activated and opportunity; matchable denominator exposed"}');

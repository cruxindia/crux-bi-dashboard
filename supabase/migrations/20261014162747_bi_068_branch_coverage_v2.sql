-- Applied to Supabase project via MCP on 20261014162747
create or replace function bi.api_branch_coverage(f jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = bi, public as $$
with m as (
  select b.*, coalesce(b.client_family, c.family, b.client_code) fam, coalesce(b.verification_status, 'admin_upload') vs
  from bi.client_branch_master b left join bi.client c on c.code = b.client_code
  where coalesce(b.branch_type, 'branch') <> 'office'),
seen as (
  select coalesce(c.family, s.client_code) fam, bi.norm_code(s.branch_code) bk, max(s.received_month) last_m, min(s.received_month) first_m, count(*) n,
         count(*) filter (where s.received_month >= (date_trunc('month', current_date) - interval '3 months')::date and s.received_month < date_trunc('month', current_date)::date) n3
  from bi.case_store s left join bi.client c on c.code = s.client_code
  where bi.norm_code(s.branch_code) is not null group by 1, 2),
cut as (select (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date c),
x as (
  select m.*, s.last_m, s.first_m, s.n, s.n3, l.label location, l.recon_unit
  from m left join seen s on s.fam = m.fam and s.bk = bi.norm_code(m.branch_code) and coalesce(m.source_type, '') <> 'official_website'
  left join bi.location l on l.id = m.location_id
  where (m.location_id is null and coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb or bi.loc_ok(m.location_id, l.recon_unit, f)) and bi.fam_ok(m.fam, f)),
ver as (select * from x where status = 'active' and vs in ('source_verified', 'admin_upload')),
peer as (  -- typical monthly cases of an active branch of the same client in the same Crux location (>= 5 active peers)
  select fam, location_id, percentile_cont(0.5) within group (order by n3 / 3.0) med, count(*) peers
  from ver where n3 > 0 and location_id is not null group by 1, 2 having count(*) >= 5),
bc as (
  select v.fam client_code, count(*) verified_active,
         count(*) filter (where v.last_m >= (select c from cut)) active_with_crux_6m,
         count(*) filter (where v.n is not null) ever_with_crux,
         count(*) filter (where v.n is null) never_activated,
         max(v.verified_on) last_verified,
         bool_or(coalesce(v.source_type, '') = 'official_website') website_source
  from ver v group by 1),
cl as (select fam, count(*) filter (where status <> 'active') closed, count(*) filter (where status = 'active' and vs = 'status_uncertain') uncertain from x group by 1)
select jsonb_build_object(
  'master_rows', (select count(*) from bi.client_branch_master),
  'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_code', bc.client_code, 'verified_active', verified_active, 'closed_or_ineligible', coalesce(cl.closed, 0),
       'status_uncertain', coalesce(cl.uncertain, 0), 'active_with_crux_6m', active_with_crux_6m, 'ever_with_crux', ever_with_crux, 'never_activated', never_activated,
       'coverage_6m', case when website_source then null else round(active_with_crux_6m::numeric / nullif(verified_active, 0), 4) end,
       'matching', case when website_source then 'not matchable by code (website list)' else 'branch code' end,
       'last_verified', last_verified) order by verified_active desc), '[]') from bc left join cl on cl.fam = bc.client_code),
  'totals', (select jsonb_build_object('verified_active', sum(verified_active), 'active_with_crux_6m', sum(active_with_crux_6m), 'never_activated', sum(never_activated),
       'coverage_6m', round(sum(active_with_crux_6m) filter (where not website_source)::numeric / nullif(sum(verified_active) filter (where not website_source), 0), 4),
       'clients_with_list', count(*)) from bc),
  'by_location', (select coalesce(jsonb_agg(jsonb_build_object('location', location, 'verified_active', n, 'active_with_crux_6m', a, 'coverage_6m', round(a::numeric / nullif(nm, 0), 4)) order by n desc), '[]')
     from (select coalesce(location, '(territory not mapped to a unit)') location, count(*) n, count(*) filter (where last_m >= (select c from cut)) a,
                  count(*) filter (where coalesce(source_type, '') <> 'official_website') nm from ver group by 1) q),
  'opportunity', (select jsonb_build_object('never_activated_with_peer_benchmark', count(*), 'indicative_cases_per_month', round(sum(p.med)::numeric, 0))
     from ver v join peer p on p.fam = v.fam and p.location_id = v.location_id where v.n is null),
  'never_activated', (select coalesce(jsonb_agg(jsonb_build_object('client', z.fam, 'branch_code', z.branch_code, 'ifsc', z.ifsc, 'branch', z.branch_name, 'type', z.branch_type,
       'city', coalesce(z.centre, z.city), 'district', z.district, 'state', z.state, 'location', z.location, 'opened_on', z.opened_on, 'verified_on', z.verified_on,
       'confidence', z.confidence, 'peer_cases_per_month', round(p.med::numeric, 1)) order by p.med desc nulls last, z.fam, z.state, z.district), '[]')
     from (select * from ver where n is null) z left join peer p on p.fam = z.fam and p.location_id = z.location_id
     where z.location_id is not null and coalesce(z.source_type, '') <> 'official_website' limit 500),
  'dormant_verified', (select coalesce(jsonb_agg(jsonb_build_object('client', fam, 'branch_code', branch_code, 'branch', branch_name, 'location', location, 'last_case_month', last_m, 'cases_total', n) order by last_m), '[]')
     from (select * from ver where n is not null and last_m < (select c from cut) order by last_m limit 500) z),
  'force_branches_not_in_master', (select count(*) from seen s where s.fam in (select distinct fam from m where coalesce(source_type, '') <> 'official_website')
     and not exists (select 1 from m where m.fam = s.fam and bi.norm_code(m.branch_code) = s.bk)),
  'method', 'Verified universe = active, source-verified branches and processing centres in the client branch master (administrative offices excluded): bank branches from the RBI IFSC directory, refreshed monthly; other lenders from their official branch locators. Active with Crux = a Force1 case in the last 6 months, matched by the bank''s branch code (leading zeros ignored). Website-sourced lists have no branch codes, so their coverage is not calculated. Never activated = verified branch with no Force1 case since Jan-2026 (Force1 history start). Indicative activation level = median monthly Force1 cases of active branches of the same client in the same Crux location (only where at least 5 such branches exist); an indication, not a forecast. Branches no longer listed by the source are kept as "status uncertain" until reviewed and excluded from coverage.')
$$;

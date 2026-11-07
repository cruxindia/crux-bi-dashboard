-- Applied to Supabase project via MCP on 20261107173647
-- wave 102f (7-Nov-2026): every verified client branch with its name and status (active / dormant / never active) for a team or client,
-- so heads can be told which branches to activate. Not cached (large, filter-specific); clients inactive PAN India excluded (owner, 7-Nov).
create or replace function bi.api_branch_list(f jsonb default '{}'::jsonb, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' set statement_timeout to '40s' as $f$
declare v_m date; v_inact text[]; v_status text := coalesce(nullif(p->>'status', ''), 'inactive');
        v_lim int := least(greatest(coalesce((p->>'limit')::int, 2000), 1), 20000); v_off int := greatest(coalesce((p->>'offset')::int, 0), 0); r jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  select x.month, array(select jsonb_array_elements_text(coalesce(x.inputs->'inactive_clients', '[]'::jsonb))) into v_m, v_inact
    from bi.potential_run x order by x.run_id desc limit 1;
  with uni as materialized (
    select distinct on (b.client_family, b.code_norm) b.branch_uid, b.client_family fam, b.code_norm code, b.branch_code, b.branch_name, b.ifsc, b.city, b.district, b.state, b.pincode,
           coalesce(b.location_id, fr.location_id) location_id, b.zone_group, b.opened_on
      from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid
     where b.status = 'active' and coalesce(b.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')
       and coalesce(b.source_type, '') <> 'official_website' and coalesce(b.branch_type, 'branch') <> 'office'
       and b.code_norm is not null and b.client_family is not null and b.client_family <> all (v_inact)
     order by b.client_family, b.code_norm, (coalesce(b.location_id, fr.location_id) is null), b.branch_uid),
  ua as materialized (
    select u.*, l.label location, coalesce(l.zone_group, l.rollup_zone, u.zone_group) zg, a.last_m, a.first_m, coalesce(a.n, 0) n, coalesce(a.n3, 0) n3,
           case when a.code_norm is null then 'never active' when a.last_m >= (v_m - interval '2 months')::date then 'active' else 'dormant' end st
      from uni u left join bi.branch_activity a on a.fam = u.fam and a.code_norm = u.code left join bi.location l on l.id = u.location_id),
  peer as (select fam, location_id, percentile_cont(0.5) within group (order by n3 / 3.0) med, count(*) k from ua where st = 'active' and n3 > 0 group by 1, 2),
  fpeer as (select fam, percentile_cont(0.5) within group (order by n3 / 3.0) med, count(*) k from ua where st = 'active' and n3 > 0 group by 1),
  rate as (select v.location_id, coalesce(c.family, v.client_code) fam, sum(v.revenue) / nullif(sum(v.cases), 0) r
             from bi.v_month_business v left join bi.client c on c.code = v.client_code
            where v.month between (v_m - interval '2 months')::date and v_m and v.cases > 0 group by 1, 2),
  frate as (select fam, sum(r * 1) / count(*) r from rate group by 1),
  u as materialized (
    select ua.*,
           case ua.st when 'active' then ua.n3 / 3.0
                      when 'dormant' then ua.n::numeric / greatest((extract(year from age(ua.last_m, ua.first_m)) * 12 + extract(month from age(ua.last_m, ua.first_m)) + 1)::int, 1)
                      else coalesce(case when pe.k >= 5 then pe.med end, case when fp.k >= 5 then fp.med end) end est_cases,
           coalesce(rt.r, fr.r) rt
      from ua left join peer pe on pe.fam = ua.fam and pe.location_id = ua.location_id left join fpeer fp on fp.fam = ua.fam
      left join rate rt on rt.location_id = ua.location_id and rt.fam = ua.fam left join frate fr on fr.fam = ua.fam
     where (f->>'client_family' is null or ua.fam = f->>'client_family')
       and case when ua.location_id is not null then bi.loc_ok(ua.location_id, null, f)
                else (f - 'client_family') = '{}'::jsonb or (f->>'zone_group' is not null and f->>'location_id' is null and f->>'stakeholder' is null and ua.zg = f->>'zone_group') end),
  sel as materialized (select * from u where case v_status when 'all' then true when 'inactive' then st <> 'active' when 'never' then st = 'never active' else st = v_status end)
  select jsonb_build_object(
    'month', v_m, 'status', v_status, 'limit', v_lim, 'offset', v_off, 'excluded_clients', to_jsonb(v_inact),
    'summary', (select jsonb_build_object('active', count(*) filter (where st = 'active'), 'dormant', count(*) filter (where st = 'dormant'), 'never', count(*) filter (where st = 'never active'),
                       'no_team', count(*) filter (where location_id is null), 'total', count(*)) from u),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_family', fam, 'active', a, 'dormant', d, 'never', nv, 'total', t) order by t desc), '[]'::jsonb)
                    from (select fam, count(*) filter (where st = 'active') a, count(*) filter (where st = 'dormant') d, count(*) filter (where st = 'never active') nv, count(*) t from u group by 1) q),
    'total_rows', (select count(*) from sel),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('client_family', fam, 'branch', branch_name, 'branch_code', branch_code, 'ifsc', ifsc, 'city', city, 'district', district, 'state', state, 'pincode', pincode,
                    'location_id', location_id, 'location', coalesce(location, 'No team yet'), 'zone_group', zg, 'status', st, 'last_case_month', last_m, 'first_case_month', first_m,
                    'cases_last3', n3, 'cases_since_jan', n, 'est_cases_month', round(est_cases, 1), 'est_rev_month', round(est_cases * rt)) order by ord), '[]'::jsonb)
               from (select s.*, row_number() over (order by s.est_cases * coalesce(s.rt, 0) desc nulls last, s.fam, s.branch_name) ord from sel s) z where ord > v_off and ord <= v_off + v_lim),
    'method', 'Verified, code-matchable client branches (official sources; website-only lists and administrative offices left out). Status from Force1 cases since Jan-2026: active = a case in the last three months (to '
      || to_char(v_m, 'Mon-YY') || '); dormant = cases earlier, none in the last three months; never active = no case since Jan-2026. Team = the location in the branch list, else the OD-010 territory rule. '
      || 'Estimated value per month: active = last three months average; dormant = its own monthly average while active; never active = median of active branches of the same client in the same team (at least 5), else of the client PAN India (at least 5); × the team x client rate. '
      || 'Clients with no business anywhere in India in the last three months are excluded: ' || coalesce(array_to_string(v_inact, ', '), 'none') || '. Sources: bi.client_branch_master, bi.branch_activity, bi.v_branch_family_rule, bi.v_month_business.')
    into r;
  return r;
end $f$;
revoke all on function bi.api_branch_list(jsonb, jsonb) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('public.bi_call(text, jsonb)'::regprocedure); o text := d;
begin
  if position('''branch_list''' in d) = 0 then
    d := replace(d, $a$  if p_fn = 'coverage_status' then return bi.api_coverage_status(); end if;$a$,
                    $a$  if p_fn = 'coverage_status' then return bi.api_coverage_status(); end if;
  if p_fn = 'branch_list' then return bi.api_branch_list(f, coalesce(p_args->'p', '{}'::jsonb)); end if;   -- wave 102f: large, filter-specific; not cached$a$);
    if d = o then raise exception 'bi_call anchor not found'; end if;
    execute d;
  end if;
end $m$;

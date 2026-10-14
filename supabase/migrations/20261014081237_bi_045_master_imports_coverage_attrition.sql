-- Applied to Supabase project via MCP on 20261014081237
-- bi_045: master data imports (client branch master, workforce master), branch coverage, attrition
create table if not exists bi.workforce_master (
  emp_key text primary key, employee_id text, name text not null, name_key text not null, role text not null,
  classification text check (classification is null or classification in ('field_executive','back_office')),
  location_id int references bi.location(id), joining_date date not null, exit_date date, exit_reason text,
  source text not null, updated_by text not null, updated_at timestamptz not null default now(),
  check (exit_date is null or exit_date >= joining_date));
create index if not exists workforce_master_name_key on bi.workforce_master(name_key);
create index if not exists case_store_branch_code_idx on bi.case_store(client_code, branch_code);
comment on table bi.workforce_master is 'Effective-dated workforce records (joining/exit) uploaded by admins; drives headcount and attrition.';

create or replace function bi.try_date(t text) returns date language plpgsql immutable as $fn$
declare s text := nullif(trim(t), '');
begin
  if s is null then return null; end if;
  if s ~ '^\d{5}(\.\d+)?$' then return date '1899-12-30' + floor(s::numeric)::int; end if;
  if s ~ '^\d{4}-\d{1,2}-\d{1,2}' then return left(s, 10)::date; end if;
  if s ~ '^\d{1,2}[-/.]\d{1,2}[-/.]\d{4}$' then return to_date(regexp_replace(s, '[/.]', '-', 'g'), 'DD-MM-YYYY'); end if;
  if s ~ '^\d{1,2}[-/ ][A-Za-z]{3}[-/ ]\d{4}$' then return to_date(regexp_replace(s, '[/ ]', '-', 'g'), 'DD-Mon-YYYY'); end if;
  if s ~ '^\d{1,2}[-/ ][A-Za-z]{3}[-/ ]\d{2}$' then return to_date(regexp_replace(s, '[/ ]', '-', 'g'), 'DD-Mon-YY'); end if;
  return null;
exception when others then return null;
end $fn$;

create or replace function bi.master_import(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare k text := p->>'kind'; dry boolean := coalesce((p->>'dry_run')::boolean, true); res jsonb;
begin
  if jsonb_array_length(coalesce(p->'rows', '[]')) > 20000 then raise exception 'At most 20,000 rows per upload'; end if;
  if k = 'branch' then
    with src as (select o rn, x from jsonb_array_elements(coalesce(p->'rows', '[]')) with ordinality t(x, o)),
    v as (select rn, x,
       coalesce((select code from bi.client where upper(code) = upper(trim(x->>'client'))),
                (select code from bi.client where upper(label) = upper(trim(x->>'client')) limit 1),
                (select client_code from bi.client_alias where upper(alias) = upper(trim(x->>'client')) and client_code is not null limit 1)) client_code,
       nullif(trim(x->>'branch_code'), '') branch_code, nullif(trim(x->>'branch_name'), '') branch_name, nullif(trim(x->>'state'), '') state, nullif(trim(x->>'city'), '') city,
       nullif(trim(x->>'location'), '') location_raw,
       case when nullif(trim(x->>'location'), '') is null then null else coalesce((select id from bi.location where upper(code) = upper(trim(x->>'location'))),
            (select id from bi.location where upper(label) = upper(trim(x->>'location')) limit 1)) end location_id,
       lower(coalesce(nullif(trim(x->>'status'), ''), 'active')) status, bi.try_date(x->>'opened_on') opened_on, bi.try_date(x->>'closed_on') closed_on,
       nullif(trim(x->>'source'), '') source, bi.try_date(x->>'verified_on') verified_on, lower(coalesce(nullif(trim(x->>'confidence'), ''), 'medium')) confidence
     from src),
    e as (select v.*, array_remove(array[
        case when client_code is null then 'unknown client "' || coalesce(x->>'client', '') || '"' end,
        case when branch_code is null then 'branch_code is required' end,
        case when status not in ('active', 'closed', 'ineligible') then 'status must be active, closed or ineligible' end,
        case when confidence not in ('high', 'medium', 'low') then 'confidence must be high, medium or low' end,
        case when source is null then 'source is required (where the branch list came from)' end,
        case when verified_on is null then 'verified_on (date) is required' end,
        case when location_raw is not null and location_id is null then 'unknown location "' || location_raw || '"' end,
        case when nullif(trim(x->>'opened_on'), '') is not null and opened_on is null then 'opened_on is not a date' end,
        case when nullif(trim(x->>'closed_on'), '') is not null and closed_on is null then 'closed_on is not a date' end], null) errs from v),
    dup as (select client_code, branch_code from e where client_code is not null and branch_code is not null group by 1, 2 having count(*) > 1),
    ok as (select * from e where cardinality(errs) = 0 and not exists (select 1 from dup d where d.client_code = e.client_code and d.branch_code = e.branch_code)),
    ins as (insert into bi.client_branch_master(client_code, branch_code, branch_name, state, city, location_id, status, opened_on, closed_on, source, verified_on, confidence, updated_by, updated_at)
            select client_code, branch_code, branch_name, state, city, location_id, status, opened_on, closed_on, source, verified_on, confidence, p_actor, now() from ok where not dry
            on conflict (client_code, branch_code) do update set branch_name = excluded.branch_name, state = excluded.state, city = excluded.city, location_id = excluded.location_id,
              status = excluded.status, opened_on = excluded.opened_on, closed_on = excluded.closed_on, source = excluded.source, verified_on = excluded.verified_on,
              confidence = excluded.confidence, updated_by = excluded.updated_by, updated_at = now()
            returning (xmax = 0) inserted)
    select jsonb_build_object('kind', 'branch', 'dry_run', dry, 'rows', (select count(*) from e), 'valid', (select count(*) from ok),
      'invalid', (select count(*) from e where cardinality(errs) > 0), 'duplicate_keys_in_file', (select count(*) from dup),
      'inserted', (select count(*) from ins where inserted), 'updated', (select count(*) from ins where not inserted),
      'already_in_master', (select count(*) from ok where exists (select 1 from bi.client_branch_master m where m.client_code = ok.client_code and m.branch_code = ok.branch_code)),
      'by_client', (select coalesce(jsonb_object_agg(client_code, n), '{}') from (select client_code, count(*) n from ok group by 1) q),
      'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', rn, 'client', x->>'client', 'key', x->>'branch_code', 'errors', to_jsonb(errs)) order by rn), '[]') from (select * from e where cardinality(errs) > 0 order by rn limit 200) z))
    into res;
  elsif k = 'workforce' then
    with src as (select o rn, x from jsonb_array_elements(coalesce(p->'rows', '[]')) with ordinality t(x, o)),
    v as (select rn, x, nullif(trim(x->>'employee_id'), '') employee_id, nullif(trim(x->>'name'), '') name, bi.norm(x->>'name') name_key, nullif(trim(x->>'role'), '') role,
       case when nullif(trim(x->>'classification'), '') is null then null
            when lower(x->>'classification') ~ 'field' then 'field_executive' when lower(x->>'classification') ~ 'back' then 'back_office' else 'invalid' end classification,
       nullif(trim(x->>'location'), '') location_raw,
       case when nullif(trim(x->>'location'), '') is null then null else coalesce((select id from bi.location where upper(code) = upper(trim(x->>'location'))),
            (select id from bi.location where upper(label) = upper(trim(x->>'location')) limit 1)) end location_id,
       bi.try_date(x->>'joining_date') joining_date, bi.try_date(x->>'exit_date') exit_date, nullif(trim(x->>'exit_reason'), '') exit_reason, nullif(trim(x->>'source'), '') source
     from src),
    e as (select v.*, coalesce(upper(employee_id), 'N:' || name_key) emp_key, array_remove(array[
        case when name is null then 'name is required' end,
        case when role is null then 'role is required' end,
        case when classification = 'invalid' then 'classification must be Field executive or Back office' end,
        case when joining_date is null then 'joining_date (date) is required' end,
        case when nullif(trim(x->>'exit_date'), '') is not null and exit_date is null then 'exit_date is not a date' end,
        case when exit_date < joining_date then 'exit_date is before joining_date' end,
        case when location_raw is not null and location_id is null then 'unknown location "' || location_raw || '"' end,
        case when source is null then 'source is required (e.g. HRMS export 14-Oct-2026)' end], null) errs from v),
    dup as (select emp_key from e group by 1 having count(*) > 1),
    ok as (select * from e where cardinality(errs) = 0 and emp_key not in (select emp_key from dup)),
    ins as (insert into bi.workforce_master(emp_key, employee_id, name, name_key, role, classification, location_id, joining_date, exit_date, exit_reason, source, updated_by, updated_at)
            select emp_key, employee_id, name, name_key, role, classification, location_id, joining_date, exit_date, exit_reason, source, p_actor, now() from ok where not dry
            on conflict (emp_key) do update set employee_id = excluded.employee_id, name = excluded.name, name_key = excluded.name_key, role = excluded.role, classification = excluded.classification,
              location_id = excluded.location_id, joining_date = excluded.joining_date, exit_date = excluded.exit_date, exit_reason = excluded.exit_reason, source = excluded.source,
              updated_by = excluded.updated_by, updated_at = now()
            returning (xmax = 0) inserted)
    select jsonb_build_object('kind', 'workforce', 'dry_run', dry, 'rows', (select count(*) from e), 'valid', (select count(*) from ok),
      'invalid', (select count(*) from e where cardinality(errs) > 0), 'duplicate_keys_in_file', (select count(*) from dup),
      'inserted', (select count(*) from ins where inserted), 'updated', (select count(*) from ins where not inserted),
      'already_in_master', (select count(*) from ok where exists (select 1 from bi.workforce_master m where m.emp_key = ok.emp_key)),
      'matched_to_force_names', (select count(*) from ok where exists (select 1 from bi.employee em where em.name_key = ok.name_key)),
      'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', rn, 'client', x->>'name', 'key', coalesce(x->>'employee_id', ''), 'errors', to_jsonb(errs)) order by rn), '[]') from (select * from e where cardinality(errs) > 0 order by rn limit 200) z))
    into res;
  else
    raise exception 'kind must be branch or workforce';
  end if;
  if not dry then
    insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'master_import', k || '_master', res - 'errors');
  end if;
  return res;
end $fn$;

create or replace function bi.api_branch_coverage(f jsonb default '{}'::jsonb) returns jsonb language sql stable security definer set search_path to 'bi','public' as $fn$
with m as (select * from bi.client_branch_master),
seen as (select client_code, upper(regexp_replace(branch_code, '^0+', '')) bk, max(received_month) last_m, min(received_month) first_m, count(*) n
         from bi.case_store where nullif(branch_code, '') is not null group by 1, 2),
cut as (select (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date c),
x as (select m.*, s.last_m, s.first_m, s.n, l.label location, l.recon_unit
      from m left join seen s on s.client_code = m.client_code and s.bk = upper(regexp_replace(m.branch_code, '^0+', ''))
      left join bi.location l on l.id = m.location_id
      where (m.location_id is null and coalesce(f, '{}'::jsonb) - 'client_family' = '{}'::jsonb or bi.loc_ok(m.location_id, l.recon_unit, f)) and bi.fam_ok(m.client_code, f)),
bc as (select client_code, count(*) filter (where status = 'active') verified_active, count(*) filter (where status <> 'active') closed_or_ineligible,
         count(*) filter (where status = 'active' and last_m >= (select c from cut)) active_with_crux_6m,
         count(*) filter (where status = 'active' and n is not null) ever_with_crux,
         count(*) filter (where status = 'active' and n is null) never_activated,
         max(verified_on) last_verified
       from x group by 1)
select jsonb_build_object(
  'master_rows', (select count(*) from m),
  'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_code', client_code, 'verified_active', verified_active, 'closed_or_ineligible', closed_or_ineligible,
       'active_with_crux_6m', active_with_crux_6m, 'ever_with_crux', ever_with_crux, 'never_activated', never_activated,
       'coverage_6m', round(active_with_crux_6m::numeric / nullif(verified_active, 0), 4), 'last_verified', last_verified) order by verified_active desc), '[]') from bc),
  'totals', (select jsonb_build_object('verified_active', sum(verified_active), 'active_with_crux_6m', sum(active_with_crux_6m), 'never_activated', sum(never_activated),
       'coverage_6m', round(sum(active_with_crux_6m)::numeric / nullif(sum(verified_active), 0), 4)) from bc),
  'never_activated', (select coalesce(jsonb_agg(jsonb_build_object('client', client_code, 'branch_code', branch_code, 'branch', branch_name, 'city', city, 'state', state, 'location', location,
       'opened_on', opened_on, 'verified_on', verified_on, 'confidence', confidence) order by client_code, state, city), '[]')
       from (select * from x where status = 'active' and n is null order by client_code, state, city limit 500) z),
  'dormant_verified', (select coalesce(jsonb_agg(jsonb_build_object('client', client_code, 'branch_code', branch_code, 'branch', branch_name, 'location', location, 'last_case_month', last_m, 'cases_total', n) order by last_m), '[]')
       from (select * from x where status = 'active' and n is not null and last_m < (select c from cut) order by last_m limit 500) z),
  'force_branches_not_in_master', (select count(*) from seen s where s.client_code in (select distinct client_code from m)
       and not exists (select 1 from m where m.client_code = s.client_code and upper(regexp_replace(m.branch_code, '^0+', '')) = s.bk)),
  'method', 'Verified universe = active branches in the uploaded client branch master. Active with Crux = a Force1 case in the last 6 months (branch code match, leading zeros ignored). Never activated = verified active branch with no Force1 case since Apr-2024. Closed/ineligible branches are excluded from coverage and opportunity.')
$fn$;

create or replace function bi.api_attrition(p_month date, f jsonb default '{}'::jsonb) returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare m date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date; me date; res jsonb;
begin
  me := (m + interval '1 month - 1 day')::date;
  f := coalesce(f, '{}'::jsonb);
  if not exists (select 1 from bi.workforce_master) then
    return jsonb_build_object('master_rows', 0, 'note', 'No workforce master uploaded yet. Upload it in Data quality → Master data (joining and exit dates per employee).');
  end if;
  with w as (select wm.*, l.label location, l.recon_unit from bi.workforce_master wm left join bi.location l on l.id = wm.location_id
             where (wm.location_id is null and f - 'client_family' = '{}'::jsonb) or (wm.location_id is not null and bi.loc_ok(wm.location_id, l.recon_unit, f, m))),
  hc as (select count(*) filter (where joining_date < m and (exit_date is null or exit_date >= m)) opening,
                count(*) filter (where joining_date between m and me) joined,
                count(*) filter (where exit_date between m and me) left_,
                count(*) filter (where joining_date <= me and (exit_date is null or exit_date > me)) closing from w),
  months as (select (m - (g || ' month')::interval)::date mm from generate_series(0, 11) g),
  tr as (select mm, count(*) filter (where w.joining_date < mm and (w.exit_date is null or w.exit_date >= mm)) opening,
                count(*) filter (where w.exit_date between mm and (mm + interval '1 month - 1 day')::date) left_,
                count(*) filter (where w.joining_date between mm and (mm + interval '1 month - 1 day')::date) joined,
                count(*) filter (where w.joining_date <= (mm + interval '1 month - 1 day')::date and (w.exit_date is null or w.exit_date > (mm + interval '1 month - 1 day')::date)) closing
         from months cross join w group by mm),
  leavers as (select w.name, w.role, w.classification, w.location, w.exit_date,
                (select round(count(*)::numeric / 3, 1) from bi.point_derived pd join bi.dim d on d.id = pd.verifier_id and d.kind = 'emp'
                  where d.val = w.name_key and pd.created_month >= (date_trunc('month', w.exit_date) - interval '3 months')::date and pd.created_month < date_trunc('month', w.exit_date)::date) prior_points_per_month,
                (select count(*) from bi.point_derived pd join bi.dim d on d.id = pd.verifier_id and d.kind = 'emp'
                  where d.val = w.name_key and pd.created_month > date_trunc('month', w.exit_date)::date) points_after_exit_month
              from w where w.exit_date between m and me),
  grp as (select coalesce(role, '(none)') k, 'role' g, count(*) filter (where joining_date <= me and (exit_date is null or exit_date > me)) closing, count(*) filter (where exit_date between m and me) left_,
                 count(*) filter (where joining_date < m and (exit_date is null or exit_date >= m)) opening from w group by 1
          union all
          select coalesce(location, '(no location)'), 'location', count(*) filter (where joining_date <= me and (exit_date is null or exit_date > me)), count(*) filter (where exit_date between m and me),
                 count(*) filter (where joining_date < m and (exit_date is null or exit_date >= m)) from w group by 1)
  select jsonb_build_object('master_rows', (select count(*) from bi.workforce_master), 'month', m, 'filters', f,
    'headcount', (select jsonb_build_object('opening', opening, 'joined', joined, 'left', left_, 'closing', closing,
        'attrition_rate', round(left_::numeric / nullif((opening + closing) / 2.0, 0), 4)) from hc),
    'trend', (select jsonb_agg(jsonb_build_object('month', mm, 'opening', opening, 'joined', joined, 'left', left_, 'closing', closing,
        'attrition_rate', round(left_::numeric / nullif((opening + closing) / 2.0, 0), 4)) order by mm) from tr),
    'by_role', (select coalesce(jsonb_agg(jsonb_build_object('group', k, 'opening', opening, 'left', left_, 'closing', closing, 'attrition_rate', round(left_::numeric / nullif((opening + closing) / 2.0, 0), 4)) order by left_ desc, closing desc), '[]') from grp where g = 'role'),
    'by_location', (select coalesce(jsonb_agg(jsonb_build_object('group', k, 'opening', opening, 'left', left_, 'closing', closing, 'attrition_rate', round(left_::numeric / nullif((opening + closing) / 2.0, 0), 4)) order by left_ desc, closing desc), '[]') from grp where g = 'location'),
    'leavers', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'role', role, 'classification', classification, 'location', location, 'exit_date', exit_date,
        'prior_points_per_month', prior_points_per_month, 'points_after_exit_month', points_after_exit_month) order by exit_date), '[]') from leavers),
    'force_people_not_in_master', (select count(*) from bi.employee e where not exists (select 1 from bi.workforce_master wm where wm.name_key = e.name_key)),
    'definitions', jsonb_build_object(
       'headcount', 'Opening = joined before the month and not exited before it; closing = joined by month end and not exited by month end.',
       'attrition_rate', 'Leavers in the month ÷ average of opening and closing headcount.',
       'prior_points_per_month', 'Average Point Wise points the leaver verified per month in the 3 months before the exit month (work to be reassigned). Observed workload, not proof of lost business.',
       'points_after_exit_month', 'Points still verified under the leaver''s name after the exit month — check the exit date or a shared login.'))
  into res;
  return res;
end $fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''branch_coverage''' in d) = 0 then
    d := replace(d, 'when ''branches'' then bi.api_branches(f)',
      'when ''branches'' then bi.api_branches(f)'||chr(10)||'      when ''branch_coverage'' then bi.api_branch_coverage(f)'||chr(10)||'      when ''attrition'' then bi.api_attrition(m, f)');
    if position('''branch_coverage''' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;

do $do$
declare d text := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
begin
  if position('master_import' in d) = 0 then
    d := replace(d, '    when ''matrix_no_report'' then',
      '    when ''master_import'' then return bi.master_import(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');' || chr(10) ||
      '    when ''matrix_no_report'' then');
    if position('master_import' in d) = 0 then raise exception 'bi_admin patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_admin(text,jsonb) to anon, authenticated;

-- Applied to Supabase project via MCP on 20261014172929
-- bi_072: client branch-list upload works with the source-verified branch master.
--  * An uploaded row is matched to an existing branch by client family + normalised code (leading zeros ignored),
--    so "011789" from the RBI directory and "11789" from a client list are one branch, not two.
--  * Official-source records are never overwritten by an upload; a different status opens a review item instead.
--  * Rows only in the upload are added as client-list records (source_type 'client_list'), with an identity and history.
--  * The coverage view is refreshed after a real (non-dry-run) upload.
create or replace function bi.master_import(p_actor text, p jsonb)
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare k text := p->>'kind'; dry boolean := coalesce((p->>'dry_run')::boolean, true); res jsonb;
        r record; v_fam text; mc text; mb text; mvs text; mst text; muid text;
        n_ins int := 0; n_upd int := 0; n_exist int := 0; n_off int := 0; n_rev int := 0;
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
    dup as (select client_code, bi.norm_code(branch_code) nc from e where client_code is not null and branch_code is not null group by 1, 2 having count(*) > 1),
    e2 as (select e.*, case when exists (select 1 from dup d where d.client_code = e.client_code and d.nc = bi.norm_code(e.branch_code))
                   then e.errs || ('client + branch_code repeated in this file (rows ' || (select string_agg(z.rn::text, ', ' order by z.rn) from e z
                        where z.client_code = e.client_code and bi.norm_code(z.branch_code) = bi.norm_code(e.branch_code)) || ')') else e.errs end errs2 from e)
    select jsonb_build_object('kind', 'branch', 'dry_run', dry, 'rows', (select count(*) from e2), 'valid', (select count(*) from e2 where cardinality(errs2) = 0),
      'invalid', (select count(*) from e2 where cardinality(errs2) > 0), 'duplicate_keys_in_file', (select count(*) from dup),
      'by_client', (select coalesce(jsonb_object_agg(client_code, n), '{}') from (select client_code, count(*) n from e2 where cardinality(errs2) = 0 group by 1) q),
      'ok', (select coalesce(jsonb_agg(jsonb_build_object('client_code', client_code, 'branch_code', branch_code, 'branch_name', branch_name, 'state', state, 'city', city,
               'location_id', location_id, 'status', status, 'opened_on', opened_on, 'closed_on', closed_on, 'source', source, 'verified_on', verified_on, 'confidence', confidence) order by rn), '[]')
             from e2 where cardinality(errs2) = 0),
      'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', rn, 'client', x->>'client', 'key', x->>'branch_code', 'errors', to_jsonb(errs2)) order by rn), '[]')
                 from (select * from e2 where cardinality(errs2) > 0 order by rn limit 200) z))
    into res;

    for r in select * from jsonb_to_recordset(res->'ok') as x(client_code text, branch_code text, branch_name text, state text, city text, location_id int,
                                                             status text, opened_on date, closed_on date, source text, verified_on date, confidence text) loop
      v_fam := coalesce((select family from bi.client where code = r.client_code), r.client_code);
      mc := null;
      select m.client_code, m.branch_code, m.verification_status, m.status, m.branch_uid into mc, mb, mvs, mst, muid
        from bi.client_branch_master m left join bi.client c on c.code = m.client_code
       where m.code_norm = bi.norm_code(r.branch_code) and coalesce(m.client_family, c.family, m.client_code) = v_fam
       order by (m.client_code = r.client_code and m.branch_code = r.branch_code) desc, (m.verification_status is null) desc
       limit 1;
      if mc is not null then n_exist := n_exist + 1; end if;
      if mc is not null and mvs is not null then
        -- official-source record: never overwritten by an upload
        n_off := n_off + 1;
        if r.status <> mst then
          n_rev := n_rev + 1;
          if not dry then
            insert into bi.branch_review(client_family, branch_uid, issue, reason, evidence)
            values (v_fam, muid, 'conflict', 'An uploaded client branch list gives a different status from the official source; the official record was not changed.',
                    jsonb_build_object('uploaded_status', r.status, 'master_status', mst, 'upload_source', r.source, 'uploaded_by', p_actor, 'verified_on', r.verified_on))
            on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set evidence = excluded.evidence;
          end if;
        end if;
      elsif mc is not null then
        if not dry then
          update bi.client_branch_master set branch_name = r.branch_name, state = r.state, city = r.city, location_id = r.location_id, status = r.status,
                 opened_on = r.opened_on, closed_on = r.closed_on, source = r.source, verified_on = r.verified_on, confidence = r.confidence,
                 updated_by = p_actor, updated_at = now()
           where client_code = mc and branch_code = mb;
          if r.status is distinct from mst then
            insert into bi.client_branch_history(branch_uid, client_family, change_type, old, new, source_version)
            values (coalesce(muid, 'UPLOAD:' || mc || ':' || mb), v_fam, 'status_changed', jsonb_build_object('status', mst), jsonb_build_object('status', r.status, 'by', p_actor), r.source);
          end if;
          n_upd := n_upd + 1;
        end if;
      else
        if not dry then
          insert into bi.client_branch_master(client_code, branch_code, branch_name, state, city, location_id, status, opened_on, closed_on, source, verified_on, confidence,
                 updated_by, updated_at, branch_uid, client_family, source_type, first_seen, last_seen)
          values (r.client_code, r.branch_code, r.branch_name, r.state, r.city, r.location_id, r.status, r.opened_on, r.closed_on, r.source, r.verified_on, r.confidence,
                 p_actor, now(), 'UPLOAD:' || r.client_code || ':' || r.branch_code, v_fam, 'client_list', r.verified_on, r.verified_on);
          insert into bi.client_branch_history(branch_uid, client_family, change_type, new, source_version)
          values ('UPLOAD:' || r.client_code || ':' || r.branch_code, v_fam, 'added', jsonb_build_object('status', r.status, 'by', p_actor), r.source);
          n_ins := n_ins + 1;
        end if;
      end if;
    end loop;
    res := (res - 'ok') || jsonb_build_object('inserted', n_ins, 'updated', n_upd, 'already_in_master', n_exist,
             'matched_official_unchanged', n_off, 'status_conflicts_for_review', n_rev);
    if not dry and n_ins + n_upd > 0 then perform bi.branch_cov_refresh(); end if;
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
    e2 as (select e.rn, e.x, e.employee_id, e.name, e.name_key, e.role, e.classification, e.location_raw, e.location_id, e.joining_date, e.exit_date, e.exit_reason, e.source, e.emp_key,
              case when e.emp_key in (select emp_key from dup)
                   then e.errs || ('same person repeated in this file (rows ' || (select string_agg(z.rn::text, ', ' order by z.rn) from e z where z.emp_key = e.emp_key) || ')') else e.errs end errs from e),
    ok as (select * from e2 where cardinality(errs) = 0),
    ins as (insert into bi.workforce_master(emp_key, employee_id, name, name_key, role, classification, location_id, joining_date, exit_date, exit_reason, source, updated_by, updated_at)
            select emp_key, employee_id, name, name_key, role, classification, location_id, joining_date, exit_date, exit_reason, source, p_actor, now() from ok where not dry
            on conflict (emp_key) do update set employee_id = excluded.employee_id, name = excluded.name, name_key = excluded.name_key, role = excluded.role, classification = excluded.classification,
              location_id = excluded.location_id, joining_date = excluded.joining_date, exit_date = excluded.exit_date, exit_reason = excluded.exit_reason, source = excluded.source,
              updated_by = excluded.updated_by, updated_at = now()
            returning (xmax = 0) inserted)
    select jsonb_build_object('kind', 'workforce', 'dry_run', dry, 'rows', (select count(*) from e), 'valid', (select count(*) from ok),
      'invalid', (select count(*) from e2 where cardinality(errs) > 0), 'duplicate_keys_in_file', (select count(*) from dup),
      'inserted', (select count(*) from ins where inserted), 'updated', (select count(*) from ins where not inserted),
      'already_in_master', (select count(*) from ok where exists (select 1 from bi.workforce_master m where m.emp_key = ok.emp_key)),
      'matched_to_force_names', (select count(*) from ok where exists (select 1 from bi.employee em where em.name_key = ok.name_key)),
      'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', rn, 'client', x->>'name', 'key', coalesce(x->>'employee_id', ''), 'errors', to_jsonb(errs)) order by rn), '[]') from (select * from e2 where cardinality(errs) > 0 order by rn limit 200) z))
    into res;
  else
    raise exception 'kind must be branch or workforce';
  end if;
  if not dry then
    insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'master_import', k || '_master', res - 'errors');
  end if;
  return res;
end $function$;

-- T24 updated for the source-verified master: matches by normalised code, official rows untouched, coverage refreshed.
create or replace function bi.test_master_data()
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare cut date := (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '6 months')::date;
        rc text; oc text; rc_in boolean; oc_in boolean; emp text; r1 jsonb; r2 jsonb; dr jsonb; c0 jsonb; c jsonb; w1 jsonb; a0 jsonb; a jsonb; lv jsonb; m date; exp_ppm numeric;
        exp_ins int; mvrow boolean; ok boolean := false; err text; chk jsonb;
begin
  select branch_code into rc from bi.case_store where client_code = 'SBI' and nullif(branch_code, '') is not null group by branch_code having max(received_month) >= cut order by count(*) desc limit 1;
  select branch_code into oc from bi.case_store where client_code = 'SBI' and nullif(branch_code, '') is not null group by branch_code having max(received_month) < cut order by count(*) desc limit 1;
  rc_in := exists (select 1 from bi.client_branch_master where client_family = 'SBI' and code_norm = bi.norm_code(rc) and verification_status is not null);
  oc_in := exists (select 1 from bi.client_branch_master where client_family = 'SBI' and code_norm = bi.norm_code(oc) and verification_status is not null);
  exp_ins := 2 + (case when rc_in then 0 else 1 end) + (case when oc_in then 0 else 1 end);
  select d.val into emp from bi.point_derived pd join bi.dim d on d.id = pd.verifier_id and d.kind = 'emp' group by d.val order by max(pd.created_month) desc, count(*) desc limit 1;
  m := (date_trunc('month', now() at time zone 'Asia/Kolkata') - interval '1 month')::date;
  select round(count(*)::numeric / 3, 1) into exp_ppm from bi.point_derived pd join bi.dim d on d.id = pd.verifier_id and d.kind = 'emp'
   where d.val = emp and pd.created_month >= (m - interval '3 months')::date and pd.created_month < m;
  c0 := bi.api_branch_coverage('{"client_family":"SBI"}');
  a0 := bi.api_attrition(m, '{}');
  begin
    dr := bi.master_import('test', jsonb_build_object('kind', 'branch', 'dry_run', true, 'rows', jsonb_build_array(
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24A', 'source', 't', 'verified_on', '2026-10-14'),
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24A', 'source', 't', 'verified_on', '2026-10-14'),
            jsonb_build_object('client', 'NO SUCH BANK', 'branch_code', 'T24B', 'source', 't', 'verified_on', 'x'))));
    r1 := bi.master_import('test', jsonb_build_object('kind', 'branch', 'dry_run', false, 'rows', jsonb_build_array(
            jsonb_build_object('client', 'SBI', 'branch_code', regexp_replace(rc, '^0+', ''), 'source', 't', 'verified_on', '2026-10-14'),
            jsonb_build_object('client', 'sbi', 'branch_code', oc, 'source', 't', 'verified_on', '14-Oct-2026'),
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24-NEVER', 'source', 't', 'verified_on', '46309'),
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24-CLOSED', 'status', 'closed', 'source', 't', 'verified_on', '2026-10-14'))));
    r2 := bi.master_import('test', jsonb_build_object('kind', 'branch', 'dry_run', false, 'rows', jsonb_build_array(
            jsonb_build_object('client', 'SBI', 'branch_code', 'T24-NEVER', 'branch_name', 'renamed', 'source', 't', 'verified_on', '2026-10-14'))));
    c := bi.api_branch_coverage('{"client_family":"SBI"}');
    mvrow := exists (select 1 from bi.branch_cov_mv v join bi.client_branch_master b on b.branch_uid = v.branch_uid
                      where v.branch_code = 'T24-NEVER' and v.vs = 'admin_upload' and b.branch_name = 'renamed');
    w1 := bi.master_import('test', jsonb_build_object('kind', 'workforce', 'dry_run', false, 'rows', jsonb_build_array(
            jsonb_build_object('name', emp, 'role', 'T24', 'joining_date', '2024-04-01', 'exit_date', (m + 14)::text, 'source', 't'),
            jsonb_build_object('name', 'T24 Stayer', 'role', 'T24', 'joining_date', '2024-01-01', 'source', 't'),
            jsonb_build_object('employee_id', 'T24-N1', 'name', 'T24 Joiner', 'role', 'T24', 'joining_date', (m + 9)::text, 'source', 't'),
            jsonb_build_object('name', 'T24 Old', 'role', 'T24', 'joining_date', '2023-01-01', 'exit_date', '2025-05-01', 'source', 't'))));
    a := bi.api_attrition(m, '{}');
    select x into lv from jsonb_array_elements(a->'leavers') x where x->>'name' = emp limit 1;
    chk := jsonb_build_object(
      'dry_run', (dr->>'valid')::int = 0 and (dr->>'invalid')::int = 3 and (dr->>'duplicate_keys_in_file')::int = 1,
      'import', (r1->>'inserted')::int = exp_ins and (r1->>'updated')::int = 0
                and (r1->>'matched_official_unchanged')::int = (case when rc_in then 1 else 0 end) + (case when oc_in then 1 else 0 end),
      'reimport', (r2->>'updated')::int = 1 and (r2->>'inserted')::int = 0,
      'verified_delta', coalesce((c->'totals'->>'verified_active')::int, 0) - coalesce((c0->'totals'->>'verified_active')::int, 0) = 1 + (case when rc_in then 0 else 1 end) + (case when oc_in then 0 else 1 end),
      'active_delta', coalesce((c->'totals'->>'active_with_crux_6m')::int, 0) - coalesce((c0->'totals'->>'active_with_crux_6m')::int, 0) = (case when rc_in then 0 else 1 end),
      'never_delta', coalesce((c->'totals'->>'never_activated')::int, 0) - coalesce((c0->'totals'->>'never_activated')::int, 0) = 1,
      'dormant_listed', exists (select 1 from jsonb_array_elements(c->'dormant_verified') x where bi.norm_code(x->>'branch_code') = bi.norm_code(oc)),
      'renamed_in_view', mvrow,
      'workforce', (w1->>'inserted')::int + (w1->>'updated')::int = 4,
      'headcount', (a->'headcount'->>'opening')::int - coalesce((a0->'headcount'->>'opening')::int, 0) = 2
                and (a->'headcount'->>'joined')::int - coalesce((a0->'headcount'->>'joined')::int, 0) = 1
                and (a->'headcount'->>'left')::int - coalesce((a0->'headcount'->>'left')::int, 0) = 1
                and (a->'headcount'->>'closing')::int - coalesce((a0->'headcount'->>'closing')::int, 0) = 2
                and (a0->>'master_rows' <> '0' or (a->'headcount'->>'attrition_rate')::numeric = 0.5),
      'leaver_ppm', (lv->>'prior_points_per_month')::numeric = exp_ppm);
    ok := not exists (select 1 from jsonb_each(chk) e where e.value <> 'true'::jsonb);
    raise exception 'rollback_t24';
  exception when others then
    err := sqlerrm;
  end;
  return jsonb_build_object('passed', ok and err = 'rollback_t24' and not exists (select 1 from bi.client_branch_master where branch_code like 'T24%')
           and not exists (select 1 from bi.workforce_master where role = 'T24'),
    'checks', chk, 'recent_branch_in_official_master', rc_in, 'old_branch_in_official_master', oc_in,
    'dry_run', dr - 'errors', 'import', r1 - 'errors', 'reimport', r2 - 'errors',
    'coverage_before', c0->'totals', 'coverage_after', c->'totals', 'attrition_month', m, 'headcount', a->'headcount',
    'leaver_prior_ppm', lv->'prior_points_per_month', 'expected_prior_ppm', exp_ppm, 'error', nullif(err, 'rollback_t24'));
end $function$;

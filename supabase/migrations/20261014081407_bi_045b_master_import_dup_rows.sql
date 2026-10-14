-- Applied to Supabase project via MCP on 20261014081407
-- bi_045b: master_import reports repeated keys as row errors
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
    e2 as (select e.rn, e.x, e.client_code, e.branch_code, e.branch_name, e.state, e.city, e.location_raw, e.location_id, e.status, e.opened_on, e.closed_on, e.source, e.verified_on, e.confidence,
              case when exists (select 1 from dup d where d.client_code = e.client_code and d.branch_code = e.branch_code)
                   then e.errs || ('client + branch_code repeated in this file (rows ' || (select string_agg(z.rn::text, ', ' order by z.rn) from e z where z.client_code = e.client_code and z.branch_code = e.branch_code) || ')') else e.errs end errs from e),
    ok as (select * from e2 where cardinality(errs) = 0),
    ins as (insert into bi.client_branch_master(client_code, branch_code, branch_name, state, city, location_id, status, opened_on, closed_on, source, verified_on, confidence, updated_by, updated_at)
            select client_code, branch_code, branch_name, state, city, location_id, status, opened_on, closed_on, source, verified_on, confidence, p_actor, now() from ok where not dry
            on conflict (client_code, branch_code) do update set branch_name = excluded.branch_name, state = excluded.state, city = excluded.city, location_id = excluded.location_id,
              status = excluded.status, opened_on = excluded.opened_on, closed_on = excluded.closed_on, source = excluded.source, verified_on = excluded.verified_on,
              confidence = excluded.confidence, updated_by = excluded.updated_by, updated_at = now()
            returning (xmax = 0) inserted)
    select jsonb_build_object('kind', 'branch', 'dry_run', dry, 'rows', (select count(*) from e), 'valid', (select count(*) from ok),
      'invalid', (select count(*) from e2 where cardinality(errs) > 0), 'duplicate_keys_in_file', (select count(*) from dup),
      'inserted', (select count(*) from ins where inserted), 'updated', (select count(*) from ins where not inserted),
      'already_in_master', (select count(*) from ok where exists (select 1 from bi.client_branch_master m where m.client_code = ok.client_code and m.branch_code = ok.branch_code)),
      'by_client', (select coalesce(jsonb_object_agg(client_code, n), '{}') from (select client_code, count(*) n from ok group by 1) q),
      'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', rn, 'client', x->>'client', 'key', x->>'branch_code', 'errors', to_jsonb(errs)) order by rn), '[]') from (select * from e2 where cardinality(errs) > 0 order by rn limit 200) z))
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
end $fn$;

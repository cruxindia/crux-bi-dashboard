-- Applied to Supabase project via MCP on 20261014143150
create or replace function bi.territory_of(p_state text, p_district text, p_pin text)
returns table(location_id int, zone_group text, basis text, confidence text) language sql stable as $$
  select location_id, zone_group, basis, confidence from (
    select t.location_id, t.zone_group, t.basis, t.confidence, 0 prio from bi.location_territory t
     where t.effective_to is null and t.state = upper(p_state) and coalesce(t.district, '*') = upper(coalesce(p_district, '~'))
    union all
    select t.location_id, t.zone_group, t.basis, t.confidence, 1 from bi.location_territory t
     where t.effective_to is null and t.state = upper(p_state) and coalesce(t.district, '*') = 'PIN:' || left(regexp_replace(coalesce(p_pin, ''), '\D', '', 'g'), 3)
    union all
    select t.location_id, t.zone_group, t.basis, t.confidence, 2 from bi.location_territory t
     where t.effective_to is null and t.state = upper(p_state) and coalesce(t.district, '*') = '*') x
  order by prio limit 1 $$;

do $$
declare d text; d2 text; a int; b int;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  a := position('  elsif op = ''apply'' then' in d);
  b := position('  elsif op = ''finish_family'' then' in d);
  if a = 0 or b = 0 then raise exception 'anchors'; end if;
  d2 := substr(d, 1, a - 1) || $apply$  elsif op = 'apply' then
    v_run := (p->>'run_id')::bigint; v_fam := p->>'family'; v_st := p->>'source_type'; v_ver := p->>'source_version';
    if not exists (select 1 from bi.job_run where id = v_run and status = 'running') then raise exception 'run % is not running', v_run; end if;
    with i as materialized (select * from bi._br_parse(p)),
    old as materialized (select m.branch_uid, m.branch_name, m.address, m.district, m.state, m.location_id, m.verification_status, m.row_hash
                         from bi.client_branch_master m join i on m.branch_uid = i.uid where i.basis is not null),
    hist as (insert into bi.client_branch_history(branch_uid, client_family, change_type, old, new, run_id, source_version)
      select i.uid, v_fam,
             case when o.verification_status = 'status_uncertain' then 'reappeared'
                  when o.branch_name is distinct from i.name then 'renamed'
                  when o.district is distinct from i.district or o.state is distinct from i.state then 'relocated'
                  when o.row_hash is distinct from i.h then 'address_changed'
                  else 'territory_changed' end,
             jsonb_build_object('name', o.branch_name, 'address', o.address, 'district', o.district, 'state', o.state, 'location_id', o.location_id, 'verification', o.verification_status),
             jsonb_build_object('name', i.name, 'address', i.address, 'district', i.district, 'state', i.state, 'location_id', i.location_id),
             v_run, v_ver
      from i join old o on o.branch_uid = i.uid
      where o.row_hash is distinct from i.h or o.location_id is distinct from i.location_id or o.verification_status = 'status_uncertain'
      returning 1),
    upd as (update bi.client_branch_master m set branch_name = i.name, address = i.address, district = i.district, state = i.state, centre = i.centre,
        city = coalesce(i.city, i.centre), pincode = i.pincode, micr = i.micr, branch_type = i.branch_type, location_id = i.location_id, zone_group = i.zone_group,
        territory_basis = i.basis, row_hash = i.h, last_seen = current_date, last_seen_run = v_run, source_version = v_ver, verified_on = current_date,
        verification_status = case when i.conf = 'high' then 'source_verified' else 'pending_confirmation' end, confidence = i.conf, status = 'active',
        aliases = case when m.branch_name is distinct from i.name and m.branch_name is not null and not (m.branch_name = any(m.aliases)) then m.aliases || m.branch_name else m.aliases end,
        updated_by = p_actor, updated_at = now()
      from i where m.branch_uid = i.uid and i.basis is not null
      returning m.branch_uid),
    ins as (insert into bi.client_branch_master(client_code, branch_code, branch_uid, client_family, ifsc, micr, branch_name, address, district, state, centre, city, pincode,
         branch_type, location_id, zone_group, territory_basis, status, source, source_type, source_url, source_version, verified_on, first_seen, last_seen, last_seen_run,
         verification_status, confidence, row_hash, updated_by, updated_at)
      select v_fam, i.code, i.uid, v_fam, i.ifsc, i.micr, i.name, i.address, i.district, i.state, i.centre, coalesce(i.city, i.centre), i.pincode,
         i.branch_type, i.location_id, i.zone_group, i.basis, 'active', coalesce(p->>'source_label', v_st), v_st, p->>'source_url', v_ver, current_date, current_date, current_date, v_run,
         case when i.conf = 'high' then 'source_verified' else 'pending_confirmation' end, i.conf, i.h, p_actor, now()
      from i where i.basis is not null and not exists (select 1 from old o where o.branch_uid = i.uid)
      on conflict (client_code, branch_code) do nothing
      returning branch_uid, branch_name, district, state, location_id),
    addh as (insert into bi.client_branch_history(branch_uid, client_family, change_type, new, run_id, source_version)
      select branch_uid, v_fam, 'added', jsonb_build_object('name', branch_name, 'district', district, 'state', state, 'location_id', location_id), v_run, v_ver from ins
      returning 1),
    rev as (update bi.branch_review b set status = 'resolved', resolved_at = now(), resolved_by = p_actor, resolution = 'Listed again in source ' || coalesce(v_ver, '')
      from old o where b.branch_uid = o.branch_uid and b.issue = 'missing_from_source' and b.status = 'open' returning 1)
    select (select count(*) from ins), (select count(*) from old o join i on i.uid = o.branch_uid where o.row_hash is distinct from i.h),
           (select count(*) from old o join i on i.uid = o.branch_uid where o.row_hash is not distinct from i.h),
           (select count(*) from i where basis is null)
           + 0 * ((select count(*) from hist) + (select count(*) from upd) + (select count(*) from addh) + (select count(*) from rev))
      into n_add, n_upd, n_same, n_out;
    update bi.job_run set heartbeat_at = now(),
      stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) || jsonb_build_object(
        'received', coalesce((stats->v_fam->>'received')::int, 0) + jsonb_array_length(coalesce(p->'rows', '[]')),
        'added', coalesce((stats->v_fam->>'added')::int, 0) + n_add, 'updated', coalesce((stats->v_fam->>'updated')::int, 0) + n_upd,
        'unchanged', coalesce((stats->v_fam->>'unchanged')::int, 0) + n_same, 'outside_territory', coalesce((stats->v_fam->>'outside_territory')::int, 0) + n_out))
     where id = v_run;
    return jsonb_build_object('ok', true, 'added', n_add, 'updated', n_upd, 'unchanged', n_same, 'outside_territory', n_out);
$apply$ || substr(d, b);
  execute d2;
end $$;

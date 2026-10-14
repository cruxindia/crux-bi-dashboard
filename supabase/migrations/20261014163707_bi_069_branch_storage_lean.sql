-- Applied to Supabase project via MCP on 20261014163707
create table if not exists bi.branch_seen(
  branch_uid text primary key,
  run_id bigint not null,
  seen_on date not null);
alter table bi.branch_seen enable row level security;
insert into bi.branch_seen(branch_uid, run_id, seen_on)
select branch_uid, last_seen_run, last_seen from bi.client_branch_master where branch_uid is not null and last_seen_run is not null
on conflict (branch_uid) do nothing;

create or replace function bi.branch_lean_compact()
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare a int; b int;
begin
  update bi.client_branch_master set source_url = null, source_version = null, source = null, updated_by = null
   where source_type in ('rbi_ifsc_directory', 'official_website') and (source_url is not null or source_version is not null or source is not null or updated_by is not null);
  get diagnostics a = row_count;
  update bi.client_branch_history set new = null where change_type = 'added' and new is not null;
  get diagnostics b = row_count;
  return jsonb_build_object('master_rows_compacted', a, 'history_rows_compacted', b);
end $$;

do $$
declare d text; d2 text; a int; b int; c int;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  a := position('  elsif op = ''apply'' then' in d);
  b := position('  elsif op = ''finish_family'' then' in d);
  c := position('  elsif op = ''run_finish'' then' in d);
  if a = 0 or b = 0 or c = 0 then raise exception 'anchors'; end if;
  d2 := substr(d, 1, a - 1) || $blk$  elsif op = 'apply' then
    v_run := (p->>'run_id')::bigint; v_fam := p->>'family'; v_st := p->>'source_type'; v_ver := p->>'source_version';
    if not exists (select 1 from bi.job_run where id = v_run and status = 'running') then raise exception 'run % is not running', v_run; end if;
    with i as materialized (select * from bi._br_parse(p)),
    old as materialized (select m.branch_uid, m.branch_name, m.address, m.district, m.state, m.location_id, m.verification_status, m.row_hash
                         from bi.client_branch_master m join i on m.branch_uid = i.uid where i.basis is not null),
    chg as materialized (select i.*, o.branch_name o_name, o.address o_address, o.district o_district, o.state o_state, o.location_id o_loc, o.verification_status o_vs, o.row_hash o_h
                         from i join old o on o.branch_uid = i.uid
                         where o.row_hash is distinct from i.h or o.location_id is distinct from i.location_id or o.verification_status is distinct from (case when i.conf = 'high' then 'source_verified' else 'pending_confirmation' end)),
    seen as (insert into bi.branch_seen(branch_uid, run_id, seen_on) select uid, v_run, current_date from i where basis is not null
             on conflict (branch_uid) do update set run_id = excluded.run_id, seen_on = excluded.seen_on returning 1),
    hist as (insert into bi.client_branch_history(branch_uid, client_family, change_type, old, new, run_id, source_version)
      select uid, v_fam,
             case when o_vs = 'status_uncertain' then 'reappeared'
                  when o_name is distinct from name then 'renamed'
                  when o_district is distinct from district or o_state is distinct from state then 'relocated'
                  when o_h is distinct from h then 'address_changed'
                  when o_loc is distinct from location_id then 'territory_changed'
                  else 'status_changed' end,
             jsonb_build_object('name', o_name, 'address', o_address, 'district', o_district, 'state', o_state, 'location_id', o_loc, 'verification', o_vs),
             jsonb_build_object('name', name, 'address', address, 'district', district, 'state', state, 'location_id', location_id),
             v_run, v_ver
      from chg returning 1),
    upd as (update bi.client_branch_master m set branch_name = c.name, address = c.address, district = c.district, state = c.state, centre = c.centre,
        city = coalesce(c.city, c.centre), pincode = c.pincode, micr = c.micr, branch_type = c.branch_type, location_id = c.location_id, zone_group = c.zone_group,
        territory_basis = c.basis, row_hash = c.h, last_seen = current_date, last_seen_run = v_run, verified_on = current_date,
        verification_status = case when c.conf = 'high' then 'source_verified' else 'pending_confirmation' end, confidence = c.conf, status = 'active',
        aliases = case when m.branch_name is distinct from c.name and m.branch_name is not null and not (m.branch_name = any(m.aliases)) then m.aliases || m.branch_name else m.aliases end,
        updated_at = now()
      from chg c where m.branch_uid = c.uid returning 1),
    ins as (insert into bi.client_branch_master(client_code, branch_code, branch_uid, client_family, ifsc, micr, branch_name, address, district, state, centre, city, pincode,
         branch_type, location_id, zone_group, territory_basis, status, source_type, verified_on, first_seen, last_seen, last_seen_run,
         verification_status, confidence, row_hash, updated_at)
      select v_fam, i.code, i.uid, v_fam, i.ifsc, i.micr, i.name, i.address, i.district, i.state, i.centre, coalesce(i.city, i.centre), i.pincode,
         i.branch_type, i.location_id, i.zone_group, i.basis, 'active', v_st, current_date, current_date, current_date, v_run,
         case when i.conf = 'high' then 'source_verified' else 'pending_confirmation' end, i.conf, i.h, now()
      from i where i.basis is not null and not exists (select 1 from old o where o.branch_uid = i.uid)
      on conflict (client_code, branch_code) do nothing
      returning branch_uid),
    addh as (insert into bi.client_branch_history(branch_uid, client_family, change_type, run_id, source_version)
      select branch_uid, v_fam, 'added', v_run, v_ver from ins where not coalesce((p->>'baseline')::boolean, false)
      returning 1),
    rev as (update bi.branch_review b set status = 'resolved', resolved_at = now(), resolved_by = p_actor, resolution = 'Listed again in source ' || coalesce(v_ver, '')
      from old o where b.branch_uid = o.branch_uid and b.issue = 'missing_from_source' and b.status = 'open' returning 1)
    select (select count(*) from ins), (select count(*) from chg where o_h is distinct from h), (select count(*) from old) - (select count(*) from chg where o_h is distinct from h),
           (select count(*) from i where basis is null)
           + 0 * ((select count(*) from seen) + (select count(*) from hist) + (select count(*) from upd) + (select count(*) from addh) + (select count(*) from rev))
      into n_add, n_upd, n_same, n_out;
    update bi.job_run set heartbeat_at = now(),
      stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) || jsonb_build_object(
        'received', coalesce((stats->v_fam->>'received')::int, 0) + jsonb_array_length(coalesce(p->'rows', '[]')),
        'added', coalesce((stats->v_fam->>'added')::int, 0) + n_add, 'updated', coalesce((stats->v_fam->>'updated')::int, 0) + n_upd,
        'unchanged', coalesce((stats->v_fam->>'unchanged')::int, 0) + n_same, 'outside_territory', coalesce((stats->v_fam->>'outside_territory')::int, 0) + n_out))
     where id = v_run;
    return jsonb_build_object('ok', true, 'added', n_add, 'updated', n_upd, 'unchanged', n_same, 'outside_territory', n_out);
  elsif op = 'finish_family' then
    v_run := (p->>'run_id')::bigint; v_fam := p->>'family'; v_st := p->>'source_type'; v_ver := p->>'source_version'; v_ok := coalesce((p->>'ok')::boolean, true);
    select count(*) into v_prev from bi.client_branch_master m left join bi.branch_seen s on s.branch_uid = m.branch_uid
     where m.client_family = v_fam and m.source_type = v_st and m.status = 'active' and coalesce(s.run_id, 0) <> v_run
       and m.verification_status is distinct from 'status_uncertain';
    if not v_ok then
      insert into bi.branch_review(client_family, issue, reason, evidence, opened_run, last_seen_run)
      values (v_fam, 'source_unavailable', 'The source could not be read completely in this run; existing records were left unchanged.', coalesce(p->'error', '{}'), v_run, v_run)
      on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run, evidence = excluded.evidence;
      update bi.client_family_research set research_status = 'partial', last_researched_at = now(), updated_at = now() where family = v_fam;
      update bi.job_run set heartbeat_at = now(), stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) || jsonb_build_object('complete', false, 'error', p->'error'))
       where id = v_run;
      return jsonb_build_object('ok', false, 'family', v_fam, 'note', 'source failure recorded; master not marked current');
    end if;
    select count(*) into v_listed from bi.client_branch_master m join bi.branch_seen s on s.branch_uid = m.branch_uid
     where m.client_family = v_fam and m.source_type = v_st and s.run_id = v_run;
    if v_prev > 25 and v_prev > 0.15 * (v_prev + v_listed) then
      v_incomplete := true;
      insert into bi.branch_review(client_family, issue, reason, evidence, opened_run, last_seen_run)
      values (v_fam, 'source_incomplete', 'Source listed far fewer branches than the master holds; nothing was marked missing.', jsonb_build_object('seen_this_run', v_listed, 'not_seen', v_prev), v_run, v_run)
      on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run, evidence = excluded.evidence;
    else
      with miss as materialized (select m.branch_uid, m.last_seen, s.seen_on from bi.client_branch_master m left join bi.branch_seen s on s.branch_uid = m.branch_uid
                    where m.client_family = v_fam and m.source_type = v_st and m.status = 'active' and coalesce(s.run_id, 0) <> v_run
                      and m.verification_status is distinct from 'status_uncertain'),
      h as (insert into bi.client_branch_history(branch_uid, client_family, change_type, old, run_id, source_version)
            select branch_uid, v_fam, 'missing_from_source', jsonb_build_object('last_seen', coalesce(seen_on, last_seen)), v_run, v_ver from miss returning 1)
      select count(*) into v_missing from h;
      update bi.client_branch_master m set verification_status = 'status_uncertain',
        research_notes = 'Not listed in source ' || coalesce(v_ver, '') || ' (' || to_char(current_date, 'DD-Mon-YYYY') || '). Absence is not proof of closure.', updated_at = now()
       from (select m2.branch_uid from bi.client_branch_master m2 left join bi.branch_seen s on s.branch_uid = m2.branch_uid
             where m2.client_family = v_fam and m2.source_type = v_st and m2.status = 'active' and coalesce(s.run_id, 0) <> v_run
               and m2.verification_status is distinct from 'status_uncertain') q
       where m.branch_uid = q.branch_uid;
      insert into bi.branch_review(client_family, branch_uid, location_id, issue, reason, evidence, opened_run, last_seen_run)
      select v_fam, branch_uid, location_id, 'missing_from_source', 'Previously listed branch is not in the latest source; check whether it closed, merged or was renamed.',
             jsonb_build_object('name', branch_name, 'district', district, 'last_seen', last_seen), v_run, v_run
      from bi.client_branch_master where client_family = v_fam and source_type = v_st and verification_status = 'status_uncertain' and status = 'active'
      on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run;
    end if;
    insert into bi.branch_review(client_family, branch_uid, location_id, issue, reason, evidence, opened_run, last_seen_run)
    select distinct on (b.branch_uid) v_fam, b.branch_uid, b.location_id, 'duplicate_candidate', 'Another branch of the same client has the same PIN code and a near-identical name.',
           jsonb_build_object('other', a.branch_uid, 'name', b.branch_name, 'other_name', a.branch_name, 'pincode', b.pincode, 'similarity', round(similarity(a.branch_name, b.branch_name)::numeric, 2)), v_run, v_run
    from bi.client_branch_master a join bi.client_branch_master b on b.client_family = a.client_family and b.pincode = a.pincode and b.branch_uid > a.branch_uid
    where a.client_family = v_fam and a.status = 'active' and b.status = 'active' and a.pincode is not null
      and similarity(a.branch_name, b.branch_name) >= 0.85 and coalesce(a.branch_type, '') = coalesce(b.branch_type, '')
      and not exists (select 1 from bi.branch_review r where r.branch_uid = b.branch_uid and r.issue = 'duplicate_candidate' and r.status <> 'open')
    order by b.branch_uid, similarity(a.branch_name, b.branch_name) desc
    on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run;
    get diagnostics v_dupes = row_count;
    if v_incomplete then
      update bi.client_family_research set research_status = 'partial', last_researched_at = now(), updated_at = now() where family = v_fam;
    else
      update bi.client_family_research set research_status = case when research_status = 'partial' and primary_source = 'official_website' then 'partial' else 'researched' end,
        last_researched_at = now(), last_verified_at = now(), source_version = v_ver,
        listed_total = nullif(p->>'listed_total', '')::int, listed_in_scope = v_listed, updated_at = now()
       where family = v_fam;
      update bi.branch_review set status = 'resolved', resolved_at = now(), resolved_by = p_actor, resolution = 'Source read completely in run ' || v_run
       where client_family = v_fam and branch_uid is null and issue in ('source_unavailable', 'source_incomplete') and status = 'open' and coalesce(last_seen_run, 0) <> v_run;
    end if;
    update bi.job_run set heartbeat_at = now(), stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) ||
        jsonb_build_object('listed_total', p->'listed_total', 'listed_in_scope', v_listed, 'newly_missing', v_missing, 'duplicate_candidates', v_dupes, 'complete', not v_incomplete))
     where id = v_run;
    return jsonb_build_object('ok', not v_incomplete, 'family', v_fam, 'seen', v_listed, 'newly_missing', v_missing, 'duplicate_candidates', v_dupes, 'incomplete', v_incomplete);
$blk$ || substr(d, c);
  execute d2;
end $$;

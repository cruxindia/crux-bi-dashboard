-- Applied to Supabase project via MCP on 20261014141133
create index if not exists client_branch_master_fam_pin on bi.client_branch_master(client_family, pincode);

create or replace function bi.branch_admin(p_actor text, p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public, extensions as $$
declare op text := p->>'op'; v_run bigint; v_fam text; n_add int := 0; n_upd int := 0; n_same int := 0; n_out int := 0;
  v_prev int; v_listed int; v_missing int := 0; v_dupes int := 0; v_st text; v_ver text; v_ok boolean; v_incomplete boolean := false;
begin
  if op = 'scope' then
    return jsonb_build_object(
      'states', (select coalesce(jsonb_agg(distinct state), '[]') from bi.location_territory where effective_to is null),
      'families', (select coalesce(jsonb_agg(jsonb_build_object('family', family, 'entity_type', entity_type, 'ifsc_bank_code', ifsc_bank_code,
                     'locator_url', locator_url, 'primary_source', primary_source) order by family), '[]') from bi.client_family_research));
  elsif op = 'evidence' then
    return (select coalesce(jsonb_agg(jsonb_build_object('family', fam, 'code', code, 'location_id', location_id, 'n', n, 'last', last_m)), '[]')
      from (select coalesce(c.family, s.client_code) fam, bi.norm_code(s.branch_code) code, s.location_id, count(*) n, max(s.received_month) last_m
            from bi.case_store s left join bi.client c on c.code = s.client_code
            where bi.norm_code(s.branch_code) is not null group by 1, 2, 3) x);
  elsif op = 'research_upsert' then
    insert into bi.client_family_research(family, display_name, entity_type, ifsc_bank_code, official_site, locator_url, primary_source, research_status, coverage_note, sources, last_researched_at, updated_at)
    select x->>'family', x->>'display_name', x->>'entity_type', nullif(x->>'ifsc_bank_code', ''), nullif(x->>'official_site', ''), nullif(x->>'locator_url', ''),
           nullif(x->>'primary_source', ''), coalesce(x->>'research_status', 'pending'), x->>'coverage_note', coalesce(x->'sources', '[]'),
           case when x ? 'researched' then now() end, now()
    from jsonb_array_elements(coalesce(p->'families', '[]')) x
    on conflict (family) do update set display_name = excluded.display_name, entity_type = excluded.entity_type, ifsc_bank_code = excluded.ifsc_bank_code,
      official_site = excluded.official_site, locator_url = excluded.locator_url, primary_source = excluded.primary_source,
      research_status = excluded.research_status, coverage_note = excluded.coverage_note, sources = excluded.sources,
      last_researched_at = coalesce(excluded.last_researched_at, bi.client_family_research.last_researched_at), updated_at = now();
    get diagnostics n_upd = row_count;
    insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'branch_research_registry', 'client_family_research', jsonb_build_object('rows', n_upd));
    return jsonb_build_object('ok', true, 'rows', n_upd);
  elsif op = 'territory_set' then
    with x as (select upper(y->>'state') state, nullif(upper(y->>'district'), '') district, nullif(y->>'location_id', '')::int location_id,
                      nullif(y->>'zone_group', '') zone_group, y->>'basis' basis, y->>'confidence' confidence
               from jsonb_array_elements(coalesce(p->'rows', '[]')) y),
    chg as (update bi.location_territory t set effective_to = current_date - 1, updated_at = now()
            from x where t.effective_to is null and t.state = x.state and coalesce(t.district, '*') = coalesce(x.district, '*')
              and (t.location_id is distinct from x.location_id or t.zone_group is distinct from x.zone_group or t.basis <> x.basis or t.confidence <> x.confidence)
            returning t.id)
    select count(*) into n_upd from chg;
    insert into bi.location_territory(location_id, zone_group, state, district, basis, confidence, evidence)
    select nullif(y->>'location_id', '')::int, nullif(y->>'zone_group', ''), upper(y->>'state'), nullif(upper(y->>'district'), ''), y->>'basis', y->>'confidence', coalesce(y->'evidence', '{}')
    from jsonb_array_elements(coalesce(p->'rows', '[]')) y
    where not exists (select 1 from bi.location_territory t where t.effective_to is null and t.state = upper(y->>'state') and coalesce(t.district, '*') = coalesce(nullif(upper(y->>'district'), ''), '*'));
    get diagnostics n_add = row_count;
    insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'branch_territory_set', 'location_territory', jsonb_build_object('inserted', n_add, 'superseded', n_upd));
    return jsonb_build_object('ok', true, 'inserted', n_add, 'superseded', n_upd);
  elsif op = 'run_start' then
    update bi.job_run set status = 'failed', finished_at = now(), errors = errors || jsonb_build_array(jsonb_build_object('error', 'stale: no heartbeat for 30 minutes'))
     where job = p->>'job' and status = 'running' and heartbeat_at < now() - interval '30 minutes';
    if exists (select 1 from bi.job_run where job = p->>'job' and status = 'running') then
      return jsonb_build_object('busy', true, 'run_id', (select max(id) from bi.job_run where job = p->>'job' and status = 'running'));
    end if;
    if not coalesce((p->>'force')::boolean, false) and exists (select 1 from bi.job_run where job = p->>'job' and status = 'succeeded'
         and source_version = p->>'source_version' and started_at > now() - interval '40 days') then
      insert into bi.job_run(job, trigger, status, finished_at, source_version, summary)
      values (p->>'job', coalesce(p->>'trigger', 'manual'), 'skipped', now(), p->>'source_version', 'Source unchanged since the last successful run; nothing to compare.')
      returning id into v_run;
      update bi.client_family_research set last_researched_at = now() where primary_source = 'rbi_ifsc_directory' and source_version = p->>'source_version';
      return jsonb_build_object('skip', true, 'run_id', v_run);
    end if;
    insert into bi.job_run(job, trigger, source_version) values (p->>'job', coalesce(p->>'trigger', 'manual'), p->>'source_version') returning id into v_run;
    return jsonb_build_object('run_id', v_run);
  elsif op = 'apply' then
    v_run := (p->>'run_id')::bigint; v_fam := p->>'family'; v_st := p->>'source_type'; v_ver := p->>'source_version';
    if not exists (select 1 from bi.job_run where id = v_run and status = 'running') then raise exception 'run % is not running', v_run; end if;
    update bi.job_run set heartbeat_at = now() where id = v_run;
    select count(*) into n_out from bi._br_parse(p) where basis is null;
    insert into bi.client_branch_history(branch_uid, client_family, change_type, old, new, run_id, source_version)
    select i.uid, v_fam,
           case when m.verification_status = 'status_uncertain' then 'reappeared'
                when m.branch_name is distinct from i.name then 'renamed'
                when m.district is distinct from i.district or m.state is distinct from i.state then 'relocated'
                when m.row_hash is distinct from i.h then 'address_changed'
                else 'territory_changed' end,
           jsonb_build_object('name', m.branch_name, 'address', m.address, 'district', m.district, 'state', m.state, 'location_id', m.location_id, 'verification', m.verification_status),
           jsonb_build_object('name', i.name, 'address', i.address, 'district', i.district, 'state', i.state, 'location_id', i.location_id),
           v_run, v_ver
    from bi._br_parse(p) i join bi.client_branch_master m on m.branch_uid = i.uid
    where i.basis is not null and (m.row_hash is distinct from i.h or m.location_id is distinct from i.location_id or m.verification_status = 'status_uncertain');
    select count(*) filter (where m.row_hash is distinct from i.h), count(*) filter (where m.row_hash is not distinct from i.h)
      into n_upd, n_same from bi._br_parse(p) i join bi.client_branch_master m on m.branch_uid = i.uid where i.basis is not null;
    update bi.client_branch_master m set branch_name = i.name, address = i.address, district = i.district, state = i.state, centre = i.centre,
        city = coalesce(i.city, i.centre), pincode = i.pincode, micr = i.micr, branch_type = i.branch_type, location_id = i.location_id, zone_group = i.zone_group,
        territory_basis = i.basis, row_hash = i.h, last_seen = current_date, last_seen_run = v_run, source_version = v_ver, verified_on = current_date,
        verification_status = case when i.conf = 'high' then 'source_verified' else 'pending_confirmation' end, confidence = i.conf, status = 'active',
        aliases = case when m.branch_name is distinct from i.name and m.branch_name is not null and not (m.branch_name = any(m.aliases)) then m.aliases || m.branch_name else m.aliases end,
        updated_by = p_actor, updated_at = now()
      from bi._br_parse(p) i where m.branch_uid = i.uid and i.basis is not null;
    insert into bi.client_branch_master(client_code, branch_code, branch_uid, client_family, ifsc, micr, branch_name, address, district, state, centre, city, pincode,
       branch_type, location_id, zone_group, territory_basis, status, source, source_type, source_url, source_version, verified_on, first_seen, last_seen, last_seen_run,
       verification_status, confidence, row_hash, updated_by, updated_at)
    select v_fam, i.code, i.uid, v_fam, i.ifsc, i.micr, i.name, i.address, i.district, i.state, i.centre, coalesce(i.city, i.centre), i.pincode,
       i.branch_type, i.location_id, i.zone_group, i.basis, 'active', coalesce(p->>'source_label', v_st), v_st, p->>'source_url', v_ver, current_date, current_date, current_date, v_run,
       case when i.conf = 'high' then 'source_verified' else 'pending_confirmation' end, i.conf, i.h, p_actor, now()
    from bi._br_parse(p) i where i.basis is not null and not exists (select 1 from bi.client_branch_master m where m.branch_uid = i.uid)
    on conflict (client_code, branch_code) do nothing;
    get diagnostics n_add = row_count;
    insert into bi.client_branch_history(branch_uid, client_family, change_type, new, run_id, source_version)
    select m.branch_uid, v_fam, 'added', jsonb_build_object('name', m.branch_name, 'district', m.district, 'state', m.state, 'location_id', m.location_id), v_run, v_ver
    from bi.client_branch_master m where m.client_family = v_fam and m.first_seen = current_date and m.last_seen_run = v_run
      and not exists (select 1 from bi.client_branch_history h where h.branch_uid = m.branch_uid and h.change_type = 'added');
    update bi.branch_review b set status = 'resolved', resolved_at = now(), resolved_by = p_actor, resolution = 'Listed again in source ' || coalesce(v_ver, '')
     from bi._br_parse(p) i where b.branch_uid = i.uid and b.issue = 'missing_from_source' and b.status = 'open';
    update bi.job_run set heartbeat_at = now(),
      stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) || jsonb_build_object(
        'received', coalesce((stats->v_fam->>'received')::int, 0) + jsonb_array_length(coalesce(p->'rows', '[]')),
        'added', coalesce((stats->v_fam->>'added')::int, 0) + n_add, 'updated', coalesce((stats->v_fam->>'updated')::int, 0) + n_upd,
        'unchanged', coalesce((stats->v_fam->>'unchanged')::int, 0) + n_same, 'outside_territory', coalesce((stats->v_fam->>'outside_territory')::int, 0) + n_out))
     where id = v_run;
    return jsonb_build_object('ok', true, 'added', n_add, 'updated', n_upd, 'unchanged', n_same, 'outside_territory', n_out);
  elsif op = 'finish_family' then
    v_run := (p->>'run_id')::bigint; v_fam := p->>'family'; v_st := p->>'source_type'; v_ver := p->>'source_version'; v_ok := coalesce((p->>'ok')::boolean, true);
    select count(*) into v_prev from bi.client_branch_master where client_family = v_fam and source_type = v_st and status = 'active' and coalesce(last_seen_run, 0) <> v_run
       and verification_status is distinct from 'status_uncertain';
    if not v_ok then
      insert into bi.branch_review(client_family, issue, reason, evidence, opened_run, last_seen_run)
      values (v_fam, 'source_unavailable', 'The source could not be read completely in this run; existing records were left unchanged.', coalesce(p->'error', '{}'), v_run, v_run)
      on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run, evidence = excluded.evidence;
      update bi.client_family_research set research_status = 'partial', last_researched_at = now(), updated_at = now() where family = v_fam;
      update bi.job_run set heartbeat_at = now(), stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) || jsonb_build_object('complete', false, 'error', p->'error'))
       where id = v_run;
      return jsonb_build_object('ok', false, 'family', v_fam, 'note', 'source failure recorded; master not marked current');
    end if;
    select count(*) into v_listed from bi.client_branch_master where client_family = v_fam and source_type = v_st and last_seen_run = v_run;
    if v_prev > 25 and v_prev > 0.15 * (v_prev + v_listed) then
      v_incomplete := true;
      insert into bi.branch_review(client_family, issue, reason, evidence, opened_run, last_seen_run)
      values (v_fam, 'source_incomplete', 'Source listed far fewer branches than the master holds; nothing was marked missing.', jsonb_build_object('seen_this_run', v_listed, 'not_seen', v_prev), v_run, v_run)
      on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run, evidence = excluded.evidence;
    else
      insert into bi.client_branch_history(branch_uid, client_family, change_type, old, run_id, source_version)
      select branch_uid, v_fam, 'missing_from_source', jsonb_build_object('last_seen', last_seen, 'source_version', source_version), v_run, v_ver
      from bi.client_branch_master where client_family = v_fam and source_type = v_st and status = 'active' and coalesce(last_seen_run, 0) <> v_run
        and verification_status is distinct from 'status_uncertain';
      get diagnostics v_missing = row_count;
      update bi.client_branch_master set verification_status = 'status_uncertain',
        research_notes = 'Not listed in source ' || coalesce(v_ver, '') || ' (' || to_char(current_date, 'DD-Mon-YYYY') || '). Absence is not proof of closure.', updated_at = now()
       where client_family = v_fam and source_type = v_st and status = 'active' and coalesce(last_seen_run, 0) <> v_run and verification_status is distinct from 'status_uncertain';
      insert into bi.branch_review(client_family, branch_uid, location_id, issue, reason, evidence, opened_run, last_seen_run)
      select v_fam, branch_uid, location_id, 'missing_from_source', 'Previously listed branch is not in the latest source; check whether it closed, merged or was renamed.',
             jsonb_build_object('name', branch_name, 'district', district, 'last_seen', last_seen), v_run, v_run
      from bi.client_branch_master where client_family = v_fam and source_type = v_st and verification_status = 'status_uncertain' and status = 'active'
      on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run;
    end if;
    insert into bi.branch_review(client_family, branch_uid, location_id, issue, reason, evidence, opened_run, last_seen_run)
    select v_fam, b.branch_uid, b.location_id, 'duplicate_candidate', 'Another branch of the same client has the same PIN code and a near-identical name.',
           jsonb_build_object('other', a.branch_uid, 'name', b.branch_name, 'other_name', a.branch_name, 'pincode', b.pincode, 'similarity', round(similarity(a.branch_name, b.branch_name)::numeric, 2)), v_run, v_run
    from bi.client_branch_master a join bi.client_branch_master b on b.client_family = a.client_family and b.pincode = a.pincode and b.branch_uid > a.branch_uid
    where a.client_family = v_fam and a.status = 'active' and b.status = 'active' and a.pincode is not null
      and similarity(a.branch_name, b.branch_name) >= 0.85 and coalesce(a.branch_type, '') = coalesce(b.branch_type, '')
    on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run;
    get diagnostics v_dupes = row_count;
    if v_incomplete then
      update bi.client_family_research set research_status = 'partial', last_researched_at = now(), updated_at = now() where family = v_fam;
    else
      update bi.client_family_research set research_status = 'researched', last_researched_at = now(), last_verified_at = now(), source_version = v_ver,
        listed_total = nullif(p->>'listed_total', '')::int, listed_in_scope = v_listed, updated_at = now()
       where family = v_fam;
      update bi.branch_review set status = 'resolved', resolved_at = now(), resolved_by = p_actor, resolution = 'Source read completely in run ' || v_run
       where client_family = v_fam and branch_uid is null and issue in ('source_unavailable', 'source_incomplete') and status = 'open' and coalesce(last_seen_run, 0) <> v_run;
    end if;
    update bi.job_run set heartbeat_at = now(), stats = jsonb_set(stats, array[v_fam], coalesce(stats->v_fam, '{}'::jsonb) ||
        jsonb_build_object('listed_total', p->'listed_total', 'listed_in_scope', v_listed, 'newly_missing', v_missing, 'duplicate_candidates', v_dupes, 'complete', not v_incomplete))
     where id = v_run;
    return jsonb_build_object('ok', not v_incomplete, 'family', v_fam, 'seen', v_listed, 'newly_missing', v_missing, 'duplicate_candidates', v_dupes, 'incomplete', v_incomplete);
  elsif op = 'run_finish' then
    v_run := (p->>'run_id')::bigint;
    update bi.job_run set finished_at = now(), heartbeat_at = now(),
      status = case when p->>'status' in ('succeeded', 'partial', 'failed') then p->>'status' else 'failed' end,
      errors = errors || coalesce(p->'errors', '[]'), summary = left(p->>'summary', 2000)
     where id = v_run and status = 'running';
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'branch_master_refresh', 'client_branch_master', v_run::text,
      (select jsonb_build_object('status', status, 'stats', stats) from bi.job_run where id = v_run));
    return (select jsonb_build_object('ok', true, 'run_id', id, 'status', status) from bi.job_run where id = v_run);
  elsif op = 'source_seen' then
    insert into bi.branch_source(source_key, url, version, published_at, content_hash, fetched_at, status, note)
    values (p->>'source_key', p->>'url', p->>'version', nullif(p->>'published_at', '')::timestamptz, p->>'content_hash', now(), p->>'status', left(p->>'note', 500))
    on conflict (source_key) do update set url = excluded.url, version = excluded.version, published_at = excluded.published_at,
      content_hash = coalesce(excluded.content_hash, bi.branch_source.content_hash), fetched_at = now(), status = excluded.status, note = excluded.note;
    return jsonb_build_object('ok', true);
  elsif op = 'source_get' then
    return coalesce((select jsonb_object_agg(source_key, to_jsonb(s) - 'source_key') from bi.branch_source s), '{}');
  elsif op = 'source_changed' then
    insert into bi.branch_review(client_family, issue, reason, evidence, opened_run, last_seen_run)
    values (p->>'family', 'source_changed', coalesce(p->>'reason', 'The official branch page changed since it was last researched; re-check the branch list.'), coalesce(p->'evidence', '{}'), nullif(p->>'run_id', '')::bigint, nullif(p->>'run_id', '')::bigint)
    on conflict (coalesce(client_family, ''), coalesce(branch_uid, ''), issue) where status = 'open' do update set last_seen_run = excluded.last_seen_run, evidence = excluded.evidence;
    return jsonb_build_object('ok', true);
  elsif op = 'review_list' then
    return (select coalesce(jsonb_agg(to_jsonb(b) order by b.opened_at desc), '[]') from (select * from bi.branch_review where status = coalesce(p->>'status', 'open')
            and (p->>'family' is null or client_family = p->>'family') order by opened_at desc limit least(coalesce((p->>'limit')::int, 200), 1000)) b);
  elsif op = 'review_resolve' then
    if coalesce(trim(p->>'resolution'), '') = '' then raise exception 'A resolution note is required'; end if;
    update bi.branch_review set status = case when p->>'status' = 'dismissed' then 'dismissed' else 'resolved' end, resolved_at = now(), resolved_by = p_actor, resolution = p->>'resolution'
     where id = (p->>'id')::bigint and status = 'open';
    get diagnostics n_upd = row_count;
    if n_upd > 0 and p->>'mark' = 'closed' then
      update bi.client_branch_master m set status = 'closed', closed_on = coalesce(nullif(p->>'closed_on', '')::date, current_date), verification_status = 'closed_verified',
        research_notes = 'Closure confirmed by ' || p_actor || ': ' || (p->>'resolution'), updated_at = now()
      from bi.branch_review b where b.id = (p->>'id')::bigint and m.branch_uid = b.branch_uid;
      insert into bi.client_branch_history(branch_uid, client_family, change_type, new)
      select b.branch_uid, b.client_family, 'closed', jsonb_build_object('closed_on', coalesce(nullif(p->>'closed_on', '')::date, current_date), 'by', p_actor, 'note', p->>'resolution')
      from bi.branch_review b where b.id = (p->>'id')::bigint and b.branch_uid is not null;
    end if;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'branch_review_resolve', 'branch_review', p->>'id', p - 'admin_key');
    return jsonb_build_object('ok', n_upd > 0);
  end if;
  raise exception 'unknown branch op %', op;
end $$;

create or replace function public.bi_branch_job(p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'forbidden'; end if;
  return bi.branch_admin('job:branch-monitor', p);
end $$;

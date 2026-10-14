-- Applied to Supabase project via MCP on 20261014141211
create or replace function bi.live_locations()
returns table(id int) language sql stable security definer set search_path = bi, public as $$
  select l.id from bi.location l
  where exists (select 1 from bi.zt_row z where z.location_id = l.id and z.snapshot_date >= current_date - 100 and coalesce(z.mtd_cases, 0) > 0)
     or exists (select 1 from bi.case_store c where c.location_id = l.id and c.received_month >= (date_trunc('month', current_date) - interval '3 months')::date) $$;

create or replace function bi.api_branch_research(f jsonb default '{}'::jsonb)
returns jsonb language sql stable security definer set search_path = bi, public as $$
with live as (
  select l.id, l.code, l.label, l.zone_group, l.region, l.recon_unit from bi.location l where l.id in (select id from bi.live_locations())),
fam as (select r.* from bi.client_family_research r where bi.fam_ok(r.family, f)),
m as (select * from bi.client_branch_master where status = 'active'),
terr as (select distinct location_id from bi.location_territory where effective_to is null and location_id is not null),
cell as (
  select fa.family, lv.id location_id, lv.label location, lv.zone_group, lv.region, fa.entity_type, fa.research_status,
         count(m.client_code) filter (where coalesce(m.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')) verified,
         count(m.client_code) filter (where m.verification_status in ('pending_confirmation', 'status_uncertain')) unconfirmed,
         lv.id in (select location_id from terr) has_territory
  from fam fa cross join live lv
  left join m on m.client_family = fa.family and m.location_id = lv.id
  where bi.loc_ok(lv.id, lv.recon_unit, f)
  group by 1, 2, 3, 4, 5, 6, 7, 10),
st as (select *, case
    when entity_type = 'not_branch_network' then 'not_applicable'
    when research_status in ('pending', 'unresolved') then 'not_researched'
    when not has_territory then 'territory_not_established'
    when verified > 0 then 'verified'
    when research_status = 'researched' then 'researched_none_in_territory'
    else 'partial' end cell_status from cell),
lastrun as (select max(id) id from bi.job_run where job = 'branch_monitor' and status in ('succeeded', 'partial'))
select jsonb_build_object(
  'clients_in_scope', (select count(*) from fam),
  'live_locations', (select count(*) from live),
  'combinations', (select count(*) from st),
  'by_status', (select coalesce(jsonb_object_agg(cell_status, n), '{}') from (select cell_status, count(*) n from st group by 1) q),
  'researched', (select count(*) from st where cell_status in ('verified', 'researched_none_in_territory', 'not_applicable')),
  'verified_cells', (select count(*) from st where cell_status = 'verified'),
  'verified_branches', (select count(*) from m where verification_status = 'source_verified'),
  'unconfirmed_branches', (select count(*) from m where verification_status in ('pending_confirmation', 'status_uncertain')),
  'outside_mapped_territory', (select count(*) from m where location_id is null),
  'added_last_run', (select coalesce(sum((v->>'added')::int), 0) from bi.job_run j, jsonb_each(j.stats) e(k, v) where j.id = (select id from lastrun) and jsonb_typeof(v) = 'object'),
  'updated_last_run', (select coalesce(sum((v->>'updated')::int), 0) from bi.job_run j, jsonb_each(j.stats) e(k, v) where j.id = (select id from lastrun) and jsonb_typeof(v) = 'object'),
  'duplicates_resolved', (select count(*) from bi.branch_review where issue = 'duplicate_candidate' and status <> 'open'),
  'open_reviews', (select coalesce(jsonb_object_agg(issue, n), '{}') from (select issue, count(*) n from bi.branch_review where status = 'open' group by 1) q),
  'last_successful_run', (select max(finished_at) from bi.job_run where job = 'branch_monitor' and status = 'succeeded'),
  'last_run', (select to_jsonb(j) - 'stats' from bi.job_run j where job = 'branch_monitor' order by id desc limit 1),
  'recent_runs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'trigger', trigger, 'started', started_at, 'finished', finished_at, 'status', status,
       'source_version', source_version, 'summary', summary, 'errors', jsonb_array_length(errors)) order by id desc), '[]')
     from (select * from bi.job_run where job = 'branch_monitor' order by id desc limit 6) j),
  'oldest_verification_days', (select (current_date - min(last_verified_at)::date) from fam where entity_type not in ('not_branch_network') and last_verified_at is not null),
  'families', (select coalesce(jsonb_agg(jsonb_build_object('family', r.family, 'name', r.display_name, 'type', r.entity_type, 'status', r.research_status,
       'source', r.primary_source, 'locator', r.locator_url, 'last_verified', r.last_verified_at, 'source_version', r.source_version,
       'listed_in_scope', r.listed_in_scope, 'note', r.coverage_note,
       'verified', (select count(*) from m where m.client_family = r.family and coalesce(m.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')),
       'in_live_territory', (select count(*) from m where m.client_family = r.family and m.location_id in (select id from live)),
       'cells_verified', (select count(*) from st where st.family = r.family and st.cell_status = 'verified'),
       'cells_total', (select count(*) from st where st.family = r.family)) order by r.entity_type, r.family), '[]') from fam r),
  'by_location', (select coalesce(jsonb_agg(jsonb_build_object('location_id', location_id, 'location', location, 'zone', zone_group, 'region', region,
       'verified_branches', v, 'clients_verified', cv, 'clients_researched_none', cn, 'clients_not_researched', nr) order by location), '[]')
     from (select location_id, location, zone_group, region, sum(verified) v, count(*) filter (where cell_status = 'verified') cv,
                  count(*) filter (where cell_status = 'researched_none_in_territory') cn, count(*) filter (where cell_status in ('not_researched', 'partial', 'territory_not_established')) nr
           from st group by 1, 2, 3, 4) q),
  'by_state', (select coalesce(jsonb_agg(jsonb_build_object('state', state, 'branches', n, 'mapped_to_location', ml) order by n desc), '[]')
     from (select state, count(*) n, count(location_id) ml from m group by 1) q),
  'method', 'Scope = every client family in the client master x every Crux location with business in the last 100 days. A combination is "verified" when the source-verified branch master holds at least one branch of that client inside that location''s territory; "researched, none in territory" when the client''s complete source was read and lists no branch there; "not applicable" for clients without a branch network. Banks: Reserve Bank of India IFSC directory (NEFT/RTGS), refreshed monthly. A short list from a website is never treated as a complete network.')
$$;

create or replace function bi.kb_admin(p_actor text, p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare v_id bigint;
begin
  if p->>'op' = 'put' then
    if coalesce(trim(p->>'title'), '') = '' or coalesce(trim(p->>'body'), '') = '' or coalesce(trim(p->>'source'), '') = '' then
      raise exception 'title, body and source are required'; end if;
    if p->>'kind' not in ('definition','method','procedure','qa','market') then raise exception 'kind must be definition, method, procedure, qa or market'; end if;
    v_id := bi.kb_put(p->>'key', p->>'kind', p->>'title', p->>'body', p->>'source');
    insert into bi.audit_log(actor, action, entity, entity_key) values (p_actor, 'kb_put', 'kb_doc', p->>'key');
    return jsonb_build_object('ok', true, 'id', v_id);
  elsif p->>'op' = 'retire' then
    update bi.kb_doc set retired_at = now() where doc_key = p->>'key' and retired_at is null;
    insert into bi.audit_log(actor, action, entity, entity_key) values (p_actor, 'kb_retire', 'kb_doc', p->>'key');
    return jsonb_build_object('ok', true);
  elsif p->>'op' = 'list' then
    return (select coalesce(jsonb_agg(jsonb_build_object('key', d.doc_key, 'kind', d.kind, 'title', d.title, 'source', d.source_ref, 'updated', d.updated_at, 'retired', d.retired_at,
       'chunks', (select count(*) from bi.kb_chunk c where c.doc_id = d.id and c.active), 'embedded', (select count(*) from bi.kb_chunk c where c.doc_id = d.id and c.active and c.embedding is not null)) order by d.kind, d.doc_key), '[]') from bi.kb_doc d);
  end if;
  raise exception 'unknown kb op';
end $$;

create or replace function bi.point_source_version()
returns bigint language sql stable security definer set search_path = bi, public as $$
  select coalesce(max(id), 0) from bi.audit_log
  where action not in ('matrix_save','matrix_commit','matrix_correction','matrix_discard','matrix_reopen','matrix_no_report','cache_bump',
                       'rate_change','rate_change_end','penalty_add','penalty_void','master_import','client_hierarchy')
    and action not like 'branch\_%' and action not like 'kb\_%' and action not like 'ai\_%' and action not like 'job\_%'
$$;

do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_admin'::regproc);
  if position('when ''branch'' then' in d) = 0 then
    d2 := replace(d, 'when ''verify'' then return jsonb_build_object(''ok'', true);',
      'when ''verify'' then return jsonb_build_object(''ok'', true);' || chr(10) ||
      '    when ''branch'' then return bi.branch_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');' || chr(10) ||
      '    when ''kb'' then return bi.kb_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');');
    if d2 = d then raise exception 'bi_admin patch anchor not found'; end if;
    execute d2;
  end if;
  d := pg_get_functiondef('public.bi_call'::regproc);
  if position('''branch_research''' in d) = 0 then
    d2 := replace(d, 'when ''branch_coverage'' then bi.api_branch_coverage(f)',
      'when ''branch_coverage'' then bi.api_branch_coverage(f)' || chr(10) ||
      '      when ''branch_research'' then bi.api_branch_research(f)' || chr(10) ||
      '      when ''ai_status'' then bi.api_ai_status()');
    d2 := replace(d2, 'if p_fn in (''exceptions'',''mapping_queue'') then
    if not v_admin then return jsonb_build_object(''error'',''admin key required''); end if;
    return case p_fn when ''exceptions'' then bi.api_exceptions() else bi.api_mapping_queue() end;
  end if;',
      'if p_fn in (''exceptions'',''mapping_queue'',''branch_reviews'') then
    if not v_admin then return jsonb_build_object(''error'',''admin key required''); end if;
    return case p_fn when ''exceptions'' then bi.api_exceptions() when ''branch_reviews'' then bi.branch_admin(''viewer'', jsonb_build_object(''op'',''review_list'',''status'',coalesce(p_args->>''status'',''open''),''family'',p_args->>''family'',''limit'',p_args->>''limit'')) else bi.api_mapping_queue() end;
  end if;');
    if position('''branch_research''' in d2) = 0 or position('''branch_reviews''' in d2) = 0 then raise exception 'bi_call patch anchor not found'; end if;
    execute d2;
  end if;
end $$;

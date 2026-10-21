-- Applied to Supabase project via MCP on 20261021175630
create or replace function bi.api_db_health() returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $$
declare res jsonb; v_all bigint := (select sum(pg_database_size(datname)) from pg_database); v_db bigint := pg_database_size(current_database());
        v_limit bigint := 500000000;
begin
  with rel as (
    select c.oid, n.nspname s, c.relname t, c.relkind k, pg_relation_size(c.oid) heap, pg_indexes_size(c.oid) idx,
           coalesce(pg_total_relation_size(c.reltoastrelid), 0) toast, pg_total_relation_size(c.oid) total, greatest(c.reltuples, 0)::bigint est_rows,
           st.n_dead_tup dead, greatest(st.last_vacuum, st.last_autovacuum) last_vac
    from pg_class c join pg_namespace n on n.oid = c.relnamespace left join pg_stat_user_tables st on st.relid = c.oid
    where n.nspname in ('bi', 'public') and c.relkind in ('r', 'm')),
  top as (select * from rel order by total desc limit 15),
  fs as (select t.t, case when t.k = 'r' and t.heap > 20000000 then (extensions.pgstattuple_approx(t.oid)).approx_free_space end free_heap from top t),
  pm as (select created_month m, count(*) n from bi.point_store where created_month >= (date_trunc('month', now()) - interval '4 months')::date
           and created_month < date_trunc('month', now())::date group by 1),
  cm as (select received_month m, count(*) n from bi.case_store where received_month >= (date_trunc('month', now()) - interval '4 months')::date
           and received_month < date_trunc('month', now())::date group by 1),
  bpr as (select (select sum(total) from rel where t in ('point_store', 'point_derived') and s = 'bi')::numeric / nullif((select count(*) from bi.point_store), 0) per_point,
                 (select total from rel where t = 'case_store' and s = 'bi')::numeric / nullif((select count(*) from bi.case_store), 0) per_case),
  gr as (select round(((select avg(n) from (select n from pm order by m desc limit 3) a) * per_point + (select avg(n) from (select n from cm order by m desc limit 3) b) * per_case) / 1e6, 1) mb_month from bpr)
  select jsonb_build_object(
    'measured_at', now(),
    'database_bytes', v_db, 'all_databases_bytes', v_all, 'limit_bytes', v_limit, 'headroom_bytes', v_limit - v_all,
    'limit_note', 'Supabase Free plan: the project becomes read-only when database size (all databases, as reported by Supabase) exceeds 500 MB. Disk size and file storage are separate.',
    'growth_mb_per_month', (select mb_month from gr),
    'days_to_limit', (select case when mb_month > 0 then round((v_limit - v_all) / 1e6 / mb_month * 30.4) end from gr),
    'top_relations', (select jsonb_agg(jsonb_build_object('table', top.s || '.' || top.t, 'kind', case top.k when 'm' then 'materialized view' else 'table' end,
                       'total', top.total, 'heap', top.heap, 'indexes', top.idx, 'toast', top.toast, 'rows_est', top.est_rows, 'dead_rows', top.dead,
                       'free_heap_bytes', fs.free_heap, 'last_vacuum', top.last_vac) order by top.total desc) from top join fs on fs.t = top.t),
    'storage_buckets', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b.id, 'public', b.public, 'objects', (select count(*) from storage.objects o where o.bucket_id = b.id),
                         'bytes', (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o where o.bucket_id = b.id), 'owner_app', 'Lumen bill extractor (keep)')), '[]') from storage.buckets b),
    'jobs', (select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'schedule', j.schedule, 'active', j.active,
               'last_run', (select max(d.start_time) from cron.job_run_details d where d.jobid = j.jobid),
               'last_status', (select d.status from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1),
               'failed_7d', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.start_time > now() - interval '7 days' and d.status <> 'succeeded'),
               'runs_7d', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.start_time > now() - interval '7 days')) order by j.jobid), '[]') from cron.job j),
    'safeguards', jsonb_build_object(
       'skip_unchanged_rows_trigger', (select coalesce(bool_and(t.tgenabled <> 'D'), false) from pg_trigger t where t.tgname = 'zz_skip_noop_update'),
       'point_derived_pkey_present', exists (select 1 from pg_class where relname = 'point_derived_pkey' and relkind = 'i'),
       'point_derived_pkey_bytes', (select pg_relation_size(oid) from pg_class where relname = 'point_derived_pkey' and relkind = 'i')),
    'actions', jsonb_build_array(
       jsonb_build_object('action', 'Upgrade the Supabase project to the Pro plan (8 GB disk included) or approve an archive design', 'who', 'Owner', 'why', 'New Force1 data adds about this much every month; cleanup alone cannot keep the database under 500 MB'),
       jsonb_build_object('action', 'Run owner_storage_cleanup.sql (drops the unused primary-key index on the rebuildable point_derived cache; re-create line included)', 'who', 'Owner (SQL editor)', 'saves_bytes', (select pg_relation_size(oid) from pg_class where relname = 'point_derived_pkey' and relkind = 'i')),
       jsonb_build_object('action', 'Review public Lumen functions callable without sign-in (for example reset_data)', 'who', 'Owner / Lumen', 'why', 'Security: the public key can call them')),
    'history', jsonb_build_array(
       jsonb_build_object('date', '2026-10-21', 'step', 'VACUUM FULL point_store, case_store, stg_row and six small tables (no rows removed; row checksums identical before/after)', 'all_databases_before', 534827185, 'all_databases_after', 482242737),
       jsonb_build_object('date', '2026-10-21', 'step', 'Trigger zz_skip_noop_update stops re-imports rewriting unchanged rows (2 dead copies per point, 3 per case before)')))
  into res;
  return res;
end $$;

create or replace function public.bi_admin(p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '120s' as $function$
begin
  if not bi.admin_ok(p->>'admin_key') then raise exception 'admin key required' using errcode='42501'; end if;
  case p_action
    when 'verify' then return jsonb_build_object('ok', true,
         'via', case when coalesce(bi.app_role() = 'admin', false) then 'account' else 'key' end,
         'expires_at', (select max(t.expires_at) from bi.ingest_token t where p->>'admin_key' is not null
                          and t.token_hash = encode(extensions.digest(p->>'admin_key', 'sha256'), 'hex') and not t.revoked and t.scope = 'admin'));
    when 'db_health' then return bi.api_db_health();
    when 'tat_rule' then return bi.tat_rule_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'tat_records' then return bi.tat_records((p->>'month')::date, coalesce(p->'filters', '{}'::jsonb), coalesce(p->>'level', 'case'), coalesce(p->'p', '{}'::jsonb));
    when 'branch' then return bi.branch_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'kb' then return bi.kb_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'mapping_retarget' then
      declare r jsonb := bi.mapping_retarget('admin-key:' || coalesce(nullif(trim(p->>'editor'), ''), 'unnamed'), p - 'admin_key');
      begin
        if coalesce((r->>'applied')::boolean, false) then
          insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('admin-key:' || coalesce(nullif(trim(p->>'editor'), ''), 'unnamed'), 'mapping_retarget', r->>'kind', r->>'alias', r);
          insert into bi.audit_log(actor, action, entity) values ('admin-key', 'request_refresh', 'point_derived');
        end if;
        return r;
      end;
    when 'mapping_update' then return bi.api_mapping_update('admin-key', p - 'admin_key');
    when 'refresh_employees' then
      insert into bi.audit_log(actor,action,entity) values ('admin-key','request_refresh','point_derived');
      return jsonb_build_object('queued', true, 'note', 'Classification and Force1 figures refresh within 10 minutes');
    when 'matrix' then return bi.api_matrix((p->>'from')::date, (p->>'to')::date);
    when 'matrix_save' then return bi.matrix_save('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'matrix_validate' then return bi.matrix_validate((p->>'date')::date);
    when 'matrix_commit' then return bi.matrix_commit('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), (p->>'date')::date, coalesce((p->>'ack')::boolean,false), p->>'reason');
    when 'matrix_reopen' then return bi.matrix_reopen('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), (p->>'date')::date, p->>'reason');
    when 'matrix_discard' then return bi.matrix_discard('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), (p->>'date')::date);
    when 'client_hierarchy' then return bi.client_hierarchy_set('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'master_import' then return bi.master_import('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'rate' then return bi.rate_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'penalty' then return bi.penalty_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'matrix_no_report' then return bi.matrix_mark_no_report('admin-key', (p->>'date')::date, p->>'reason');
    when 'groups' then return bi.api_groups();
    when 'group_preview' then return bi.group_change_preview(p - 'admin_key');
    when 'group_apply' then return bi.group_change_apply('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'group_history' then return bi.api_group_history(p - 'admin_key');
    when 'zone_edit' then return bi.zone_group_edit('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    else raise exception 'unknown action';
  end case;
end $function$;

create or replace function public.bi_call(p_fn text, p_args jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '45s' as $function$
declare m date := nullif(p_args->>'month','')::date; f jsonb := coalesce(p_args->'filters','{}');
        v_admin boolean := bi.admin_ok(p_args->>'admin_key');
        v_ver bigint := (select coalesce(max(id),0) from bi.audit_log) * 100000 + coalesce((select (extract(epoch from max(refreshed_at))::bigint % 100000) from bi.refresh_state), 0);
        v_key text := md5(p_fn || '|' || coalesce((p_args - 'admin_key')::text,''));
        r jsonb;
begin
  if p_fn in ('exceptions','mapping_queue','branch_reviews','fin_review','fin_records') then
    if not v_admin then return jsonb_build_object('error','admin key required'); end if;
    return case p_fn when 'exceptions' then bi.api_exceptions() when 'fin_review' then bi.api_fin_review(coalesce(p_args->'p', '{}'::jsonb)) when 'fin_records' then bi.api_fin_records(coalesce(p_args->'p', '{}'::jsonb)) when 'branch_reviews' then bi.branch_admin('viewer', jsonb_build_object('op','review_list','status',coalesce(p_args->>'status','open'),'family',p_args->>'family','limit',p_args->>'limit')) else bi.api_mapping_queue() end;
  end if;
  select v into r from bi.api_cache where k = v_key and version = v_ver;
  if r is null then
    r := case p_fn
      when 'meta' then bi.api_meta()
      when 'overview' then bi.api_overview(m,f) when 'forecast' then bi.api_forecast(m,f)
      when 'zonal' then bi.api_zonal((p_args->>'snapshot')::date,f) when 'daily' then bi.api_daily(m,f)
      when 'monthly' then bi.api_monthly((p_args->>'from')::date,(p_args->>'to')::date,f,coalesce(p_args->>'group','total'))
      when 'force' then bi.api_force(m,f) when 'force_trend' then bi.api_force_trend(f)
      when 'case_tat' then bi.api_case_tat(m,f,coalesce(p_args->>'group','location'))
      when 'point_tat' then bi.api_point_tat(m,f,coalesce(p_args->>'group','category'))
      when 'manual_tat' then bi.api_manual_tat(m,f) when 'employees' then bi.api_employees(m,f) when 'insights' then bi.api_insights(m,f)
      when 'force1' then bi.api_force1(m,f)
      when 'tat_trend' then bi.tat_trend(f, coalesce((p_args->>'months')::int, 12))
      when 'force1_recon' then bi.api_force1_recon(m,f)
      when 'branches' then bi.api_branches(f)
      when 'branch_coverage' then bi.api_branch_coverage(f)
      when 'branch_research' then bi.api_branch_research(f)
      when 'ai_status' then bi.api_ai_status()
      when 'drill' then bi.api_drill(m, f, coalesce(p_args->>'level', 'zone'), coalesce(p_args->'p', '{}'::jsonb))
      when 'drill_ops' then bi.api_drill_ops(m, f, coalesce(p_args->>'level', 'none'), coalesce(p_args->>'part', 'tat'))
      when 'tat_summary' then bi.tat_summary(m, f, coalesce(p_args->>'group', 'total'))
      when 'branch_detail' then bi.api_branch_detail(coalesce(p_args->'p', '{}'::jsonb))
      when 'potential' then bi.api_potential(m, f, coalesce(p_args->>'measure', 'revenue'), coalesce(p_args->>'group', 'location'))
      when 'organic' then bi.api_organic(m, f, coalesce(p_args->>'group', 'location'), coalesce(p_args->>'measure', 'cases'))
      when 'organic_trend' then bi.api_organic_trend(f, coalesce((p_args->>'months')::int, 12))
      when 'penalty' then bi.api_penalty(m, f)
      when 'attrition' then bi.api_attrition(m, f)
      when 'business_count' then bi.api_business_count(m, f, coalesce(p_args->>'measure','revenue'))
      when 'tracker_sheet' then bi.api_tracker_sheet(nullif(p_args->>'snapshot','')::date, f, nullif(p_args->>'compare','')::date, coalesce((p_args->>'history')::int, 6))
      when 'compare' then bi.api_compare(p_args, f)
      when 'lfl' then bi.api_lfl(m,f,coalesce(p_args->>'group','location'))
      when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)
      when 'collections' then bi.api_collections(m, f)
      when 'growth' then bi.api_growth(m, f, coalesce(p_args->'p', '{}'::jsonb))
      else null end;
    if r is not null then
      insert into bi.api_cache(k, v, version) values (v_key, r, v_ver)
      on conflict (k) do update set v = excluded.v, version = excluded.version, computed_at = now();
    end if;
  end if;
  -- penalty reasons and names of who entered them: admins only
  if p_fn = 'penalty' and not v_admin and jsonb_typeof(r->'entries') = 'array' then
    r := jsonb_set(r, '{entries}', (select coalesce(jsonb_agg((x - 'reason' - 'reference' - 'by') order by o), '[]'::jsonb) from jsonb_array_elements(r->'entries') with ordinality t(x, o)));
    r := r || jsonb_build_object('reasons_hidden', true);
  end if;
  -- leaver names are HR data: admins only
  if p_fn = 'attrition' and not v_admin and jsonb_typeof(r->'leavers') = 'array' then
    r := jsonb_set(r, '{leavers}', (select coalesce(jsonb_agg((x - 'name') || jsonb_build_object('name', '(admin only)') order by o), '[]'::jsonb) from jsonb_array_elements(r->'leavers') with ordinality t(x, o)));
    r := r || jsonb_build_object('names_hidden', true);
  end if;
  if p_fn = 'meta' then r := r || jsonb_build_object('role', case when v_admin then 'admin' else 'viewer' end); end if;
  return r;
end $function$;

-- Applied to Supabase project via MCP on 20261014075258
create or replace function bi.matrix_commit(p_actor text, p_date date, p_ack_warnings boolean, p_reason text) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare v jsonb := bi.matrix_validate(p_date); reopened boolean := coalesce((v->>'reopened')::boolean, false);
        prev date := bi.matrix_template(p_date); sm boolean; b bigint; h text; old_batch bigint; old_file text; arch bigint;
begin
  sm := prev is not null and date_trunc('month', prev) = date_trunc('month', p_date);
  if (v->>'errors')::int > 0 then return jsonb_build_object('committed', false, 'reason', 'validation errors', 'validation', v); end if;
  if (v->>'warnings')::int > 0 and not coalesce(p_ack_warnings, false) then return jsonb_build_object('committed', false, 'reason', 'warnings need acknowledgement', 'validation', v); end if;
  if (reopened or (v->>'warnings')::int > 0) and coalesce(length(trim(p_reason)), 0) < 5 then
    return jsonb_build_object('committed', false, 'reason', 'a reason (5+ characters) is required for a correction or for accepting warnings', 'validation', v); end if;
  select md5(string_agg(location_label||'|'||client_label||'|'||coalesce(mtd_cases::text,'')||'|'||coalesce(target_cases::text,'')||'|'||coalesce(rate::text,''), ',' order by location_label, client_label))
    into h from bi.zt_matrix_draft where snapshot_date = p_date and committed_batch is null;
  insert into bi.import_batch(source_category, file_name, file_hash, period_month, snapshot_date, status, rows_in, rows_new, uploaded_by, committed_at, notes)
  values ('zonal', case when reopened then 'matrix-correction:' else 'matrix:' end || p_date,
          'matrix:' || p_date || ':' || h || case when reopened then ':' || floor(extract(epoch from clock_timestamp()))::bigint else '' end,
          date_trunc('month', p_date)::date, p_date, 'committed', (v->>'rows_entered')::int, (v->>'rows_entered')::int, p_actor, now(),
          case when reopened then 'Correction of committed snapshot' else 'Daily matrix entry; template ' || prev end || coalesce('; reason: ' || p_reason, ''))
  returning id into b;

  if reopened then
    select batch_id, file_name into old_batch, old_file from bi.zt_snapshot where snapshot_date = p_date;
    insert into bi.zt_snapshot_archive(snapshot_date, archived_by, reason, batch_id, file_name, rows)
    values (p_date, p_actor, p_reason, old_batch, old_file,
            (select jsonb_agg(jsonb_build_object('sheet_row', sheet_row, 'location', location_label, 'client', client_label, 'target', target_cases, 'mtd', mtd_cases, 'rate', rate,
                     'revenue_target', revenue_target, 'revenue', revenue_actual, 'bd_revenue', bd_revenue) order by sheet_row)
             from bi.zt_row where snapshot_date = p_date and row_type = 'leaf'))
    returning id into arch;
    update bi.zt_row z set target_cases = x.tgt, mtd_cases = x.cur, rate = x.rate, revenue_target = x.tgt * x.rate, revenue_actual = x.cur * x.rate,
           achievement = x.cur / nullif(x.tgt, 0), shortfall_revenue = x.cur * x.rate - x.tgt * x.rate,
           src_daily_value = x.cur - coalesce(x.pm, 0), src_prev_value = coalesce(x.pm, 0)
    from (select l.sheet_row, d.mtd_cases cur, coalesce(d.target_cases, l.target_cases) tgt, coalesce(d.rate, l.rate) rate,
                 case when sm then (select p.mtd_cases from bi.zt_row p where p.snapshot_date = prev and p.row_type = 'leaf' and p.location_label = l.location_label and p.client_label = l.client_label limit 1) end pm
          from bi.zt_row l join bi.zt_matrix_draft d on d.snapshot_date = p_date and d.committed_batch is null and d.location_label = l.location_label and d.client_label = l.client_label
          where l.snapshot_date = p_date and l.row_type = 'leaf') x
    where z.snapshot_date = p_date and z.sheet_row = x.sheet_row;
    update bi.zt_row set target_cases = null, mtd_cases = null where snapshot_date = p_date and row_type <> 'leaf';
    update bi.zt_snapshot set batch_id = b, file_name = 'matrix-correction:' || p_date, loaded_at = now() where snapshot_date = p_date;
  else
    insert into bi.zt_snapshot(snapshot_date, report_month, batch_id, file_name, pan_india_target, pan_india_mtd)
    values (p_date, date_trunc('month', p_date)::date, b, 'matrix:' || p_date, 0, 0);
    insert into bi.zt_row(snapshot_date, sheet_row, row_type, zone_group, location_label, client_label, location_id, client_code, target_cases, mtd_cases, rate,
       revenue_target, revenue_actual, achievement, bd_revenue, shortfall_revenue, expense_projected, margin_after_expense, col_n_value, src_daily_value, src_prev_value, region_label)
    select p_date, r.sheet_row, r.row_type, r.zone_group, r.location_label, r.client_label, r.location_id, r.client_code,
       x.tgt, x.cur, x.rate, x.tgt * x.rate, x.cur * x.rate, x.cur / nullif(x.tgt, 0), null, x.cur * x.rate - x.tgt * x.rate, null, null, null,
       x.cur - case when sm then r.mtd_cases else 0 end, case when sm then r.mtd_cases else 0 end, r.region_label
    from bi.zt_row r join lateral (select d.mtd_cases cur, coalesce(d.target_cases, case when sm then r.target_cases end) tgt, coalesce(d.rate, r.rate) rate
          from bi.zt_matrix_draft d where d.snapshot_date = p_date and d.committed_batch is null and d.location_label = r.location_label and d.client_label = r.client_label) x on true
    where r.snapshot_date = prev and r.row_type = 'leaf';
    insert into bi.zt_row(snapshot_date, sheet_row, row_type, zone_group, location_label, client_label, region_label)
    select p_date, r.sheet_row, r.row_type, r.zone_group, r.location_label, r.client_label, r.region_label
    from bi.zt_row r where r.snapshot_date = prev and r.row_type <> 'leaf';
  end if;

  update bi.zt_row z set revenue_actual = (select sum(l.revenue_actual) from bi.zt_row l where l.snapshot_date = p_date and l.row_type = 'leaf' and l.sheet_row < z.sheet_row
         and l.sheet_row > coalesce((select max(p.sheet_row) from bi.zt_row p where p.snapshot_date = p_date and p.row_type in ('location_total','zone_total') and p.sheet_row < z.sheet_row), 0))
   where z.snapshot_date = p_date and z.row_type = 'location_total';
  update bi.zt_row z set revenue_actual = (select sum(l.revenue_actual) from bi.zt_row l where l.snapshot_date = p_date and l.row_type = 'leaf' and l.zone_group = z.zone_group)
   where z.snapshot_date = p_date and z.row_type = 'zone_total';
  update bi.zt_snapshot set pan_india_target = (select sum(target_cases) from bi.zt_row where snapshot_date = p_date and row_type = 'leaf'),
         pan_india_mtd = (select sum(mtd_cases) from bi.zt_row where snapshot_date = p_date and row_type = 'leaf') where snapshot_date = p_date;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (p_actor, case when reopened then 'matrix_correction' else 'matrix_commit' end, 'zt_snapshot', p_date::text,
     jsonb_build_object('batch', b, 'template', prev, 'rows', v->'rows_entered', 'total_mtd', v->'total_mtd', 'prev_total_mtd', v->'prev_total_mtd',
       'old_total_mtd', v->'old_total_mtd', 'warnings', v->'warnings', 'reason', p_reason, 'archive_id', arch, 'replaced_batch', old_batch,
       'changes', v->'changes', 'control_mtd', v->'control_mtd',
       'values', (select jsonb_agg(jsonb_build_object('l', location_label, 'c', client_label, 'mtd', mtd_cases, 'target', target_cases, 'rate', rate, 'by', entered_by))
                  from bi.zt_matrix_draft where snapshot_date = p_date and committed_batch is null)));
  update bi.zt_matrix_draft set committed_batch = b where snapshot_date = p_date and committed_batch is null;
  update bi.zt_reopen set active = false where snapshot_date = p_date;
  return jsonb_build_object('committed', true, 'correction', reopened, 'batch', b, 'snapshot', p_date, 'total_mtd', v->'total_mtd', 'old_total_mtd', v->'old_total_mtd',
     'rows', v->'rows_entered', 'changed', v->'changed_vs_committed', 'archive_id', arch);
end $fn$;

create or replace function bi.matrix_reopen(p_actor text, p_date date, p_reason text) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare n int;
begin
  if not exists (select 1 from bi.zt_snapshot where snapshot_date = p_date) then raise exception 'No committed tracker snapshot for %', p_date; end if;
  if coalesce(length(trim(p_reason)), 0) < 5 then raise exception 'Give a reason for the correction (at least 5 characters)'; end if;
  insert into bi.zt_reopen(snapshot_date, reopened_by, reason, active) values (p_date, p_actor, trim(p_reason), true)
  on conflict (snapshot_date) do update set reopened_by = excluded.reopened_by, reason = excluded.reason, reopened_at = now(), active = true;
  insert into bi.zt_matrix_draft(snapshot_date, location_label, client_label, mtd_cases, target_cases, rate, entered_by)
  select p_date, location_label, client_label, mtd_cases, target_cases, rate, p_actor || ' (copied from committed)'
  from bi.zt_row where snapshot_date = p_date and row_type = 'leaf'
  on conflict (snapshot_date, location_label, client_label) do update set mtd_cases = excluded.mtd_cases, target_cases = excluded.target_cases, rate = excluded.rate,
    entered_by = excluded.entered_by, entered_at = now(), committed_batch = null;
  get diagnostics n = row_count;
  insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'matrix_reopen', 'zt_snapshot', p_date::text, jsonb_build_object('reason', p_reason, 'rows_copied', n));
  return jsonb_build_object('reopened', true, 'date', p_date, 'rows_copied', n);
end $fn$;

create or replace function bi.matrix_discard(p_actor text, p_date date) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare n int; was_reopened boolean := exists (select 1 from bi.zt_reopen where snapshot_date = p_date and active);
begin
  update bi.zt_matrix_draft set mtd_cases = null, target_cases = null, rate = null, entered_by = p_actor || ' (discarded)', entered_at = now()
   where snapshot_date = p_date and committed_batch is null;
  get diagnostics n = row_count;
  update bi.zt_reopen set active = false where snapshot_date = p_date;
  update bi.zt_matrix_meta set control_mtd = null, updated_by = p_actor, updated_at = now() where snapshot_date = p_date;
  insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'matrix_discard', 'zt_matrix_draft', p_date::text, jsonb_build_object('rows', n, 'was_correction', was_reopened));
  return jsonb_build_object('discarded', n, 'date', p_date, 'was_correction', was_reopened);
end $fn$;

create or replace function bi.api_matrix(p_from date, p_to date) returns jsonb language sql stable security definer set search_path to 'bi','public' as $fn$
with d as (select g::date dt from generate_series(p_from, least(p_to, (now() at time zone 'Asia/Kolkata')::date), '1 day') g),
dates as (select dt,
   case when exists (select 1 from bi.zt_reopen r where r.snapshot_date = dt and r.active) then 'reopened'
        when exists (select 1 from bi.zt_snapshot s where s.snapshot_date = dt) then 'loaded'
        when exists (select 1 from bi.report_calendar_exception e where e.report_date = dt) then 'no_report'
        when exists (select 1 from bi.zt_matrix_draft m where m.snapshot_date = dt and m.committed_batch is null and coalesce(m.mtd_cases, m.target_cases, m.rate) is not null) then 'draft'
        when extract(isodow from dt) = 7 then 'not_expected'
        else 'missing' end status,
   (select jsonb_build_object('file', s.file_name, 'by', b.uploaded_by, 'at', coalesce(b.committed_at, s.loaded_at), 'mtd', s.pan_india_mtd)
      from bi.zt_snapshot s left join bi.import_batch b on b.id = s.batch_id where s.snapshot_date = dt) info,
   (select control_mtd from bi.zt_matrix_meta where snapshot_date = dt) control,
   (select reason from bi.report_calendar_exception where report_date = dt) no_report_reason,
   (select jsonb_build_object('by', reopened_by, 'at', reopened_at, 'reason', reason) from bi.zt_reopen where snapshot_date = dt and active) reopen
 from d),
tpl as (select max(snapshot_date) t from bi.zt_snapshot where snapshot_date <= p_to),
dr as (select location_label, client_label, jsonb_object_agg(snapshot_date, jsonb_strip_nulls(jsonb_build_object('mtd', mtd_cases, 'target', target_cases, 'rate', rate))) j
       from bi.zt_matrix_draft where snapshot_date between p_from and p_to and committed_batch is null and coalesce(mtd_cases, target_cases, rate) is not null group by 1, 2),
cm as (select location_label, client_label, jsonb_object_agg(snapshot_date, mtd_cases) j
       from bi.zt_row where row_type = 'leaf' and snapshot_date between p_from and p_to group by 1, 2),
rows as (select r.sheet_row, r.location_label, r.client_label, r.rate, r.target_cases, r.mtd_cases, r.zone_group, l.stakeholder, l.region, l.tier, dr.j drafts, cm.j committed
  from bi.zt_row r join tpl on r.snapshot_date = tpl.t left join bi.location l on l.id = r.location_id
  left join dr on dr.location_label = r.location_label and dr.client_label = r.client_label
  left join cm on cm.location_label = r.location_label and cm.client_label = r.client_label
  where r.row_type = 'leaf')
select jsonb_build_object(
  'template_snapshot', (select t from tpl),
  'dates', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('date', dt, 'status', status, 'info', info, 'control', control, 'reason', no_report_reason, 'reopen', reopen)) order by dt) from dates),
  'rows', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('r', sheet_row, 'zone', zone_group, 'location', location_label, 'client', client_label, 'stakeholder', stakeholder,
             'region', region, 'tier', tier, 'rate', rate, 'target', target_cases, 'last_mtd', mtd_cases, 'drafts', drafts, 'committed', committed)) order by sheet_row) from rows),
  'cadence_note', 'Expected dates = Monday–Saturday (observed tracker cadence) minus admin-marked no-report days. Rows and order come from the latest tracker snapshot on or before the end of the range.')
$fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure); d0 text := d;
begin
  if position('matrix_reopen' in d) = 0 then
    d := replace(d, '    when ''matrix_no_report'' then',
      '    when ''matrix_reopen'' then return bi.matrix_reopen(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), (p->>''date'')::date, p->>''reason'');' || chr(10) ||
      '    when ''matrix_discard'' then return bi.matrix_discard(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), (p->>''date'')::date);' || chr(10) ||
      '    when ''client_hierarchy'' then return bi.client_hierarchy_set(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');' || chr(10) ||
      '    when ''matrix_no_report'' then');
    d := replace(d, 'when ''matrix_save'' then return bi.matrix_save(''admin-key'', p);',
                    'when ''matrix_save'' then return bi.matrix_save(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');');
    d := replace(d, 'when ''matrix_commit'' then return bi.matrix_commit(''admin-key'',',
                    'when ''matrix_commit'' then return bi.matrix_commit(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''),');
    if d = d0 or position('matrix_discard' in d) = 0 then raise exception 'bi_admin patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_admin(text,jsonb) to anon, authenticated;

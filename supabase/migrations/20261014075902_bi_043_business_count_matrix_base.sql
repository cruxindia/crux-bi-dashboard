-- Applied to Supabase project via MCP on 20261014075902
create or replace function bi.api_business_count(p_month date, f jsonb default '{}'::jsonb, p_measure text default 'revenue')
returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare m date := date_trunc('month', coalesce(p_month, (select max(report_month) from bi.zt_snapshot)))::date; meas text := case when p_measure = 'cases' then 'cases' else 'revenue' end;
        latest date; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  latest := (select max(snapshot_date) from bi.zt_snapshot where report_month = m);
  if latest is null then return jsonb_build_object('error', 'No tracker snapshots for this month'); end if;
  with snaps as (select snapshot_date d, lag(snapshot_date) over (order by snapshot_date) pd from bi.zt_snapshot where report_month = m),
  leaf as (select z.snapshot_date d, z.location_id, z.sheet_row,
                  case when meas = 'cases' then z.mtd_cases else z.revenue_actual end v,
                  case when meas = 'cases' then z.target_cases else z.revenue_target end t
           from bi.zt_row z join snaps s on s.d = z.snapshot_date left join bi.location l on l.id = z.location_id
           where z.row_type = 'leaf' and bi.loc_ok(z.location_id, l.recon_unit, f, z.snapshot_date) and bi.fam_ok(z.client_code, f)),
  loc as (select d, location_id, sum(v) v, sum(t) t from leaf group by 1, 2),
  daily as (select s.d, l.location_id, l.v - coalesce(p.v, 0) dv, l.v mtd, l.t from snaps s join loc l on l.d = s.d left join loc p on p.d = s.pd and p.location_id = l.location_id),
  cols as (select l.id location_id, l.label, l.code,
                  (select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(l.id, 'zone_group', latest)) zone, min(lf.sheet_row) ord
           from bi.location l join leaf lf on lf.location_id = l.id and lf.d = latest group by l.id, l.label, l.code),
  per as (select location_id, sum(dv) total, avg(dv) avg_day, count(*) days from daily group by 1),
  tgt as (select location_id, t from loc where d = latest),
  dd as (select d, jsonb_object_agg(location_id::text, dv) cells, sum(dv) total from daily group by d)
  select jsonb_build_object(
    'month', m, 'measure', meas, 'latest_snapshot', latest, 'filters', f,
    'columns', (select coalesce(jsonb_agg(jsonb_build_object('location_id', location_id, 'label', label, 'code', code, 'zone', zone) order by ord), '[]') from cols),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'cells', cells, 'total', total) order by d), '[]') from dd),
    'summary', (select coalesce(jsonb_object_agg(c.location_id::text, jsonb_build_object('total', p.total, 'target', t.t, 'shortfall', p.total - t.t, 'avg_day', round(p.avg_day))), '{}')
                from cols c left join per p on p.location_id = c.location_id left join tgt t on t.location_id = c.location_id),
    'grand', (select jsonb_build_object('total', sum(p.total), 'target', (select sum(t) from tgt), 'shortfall', sum(p.total) - (select sum(t) from tgt),
                 'avg_day', round((select avg(total) from dd))) from per p),
    'method', 'Each cell = this report date''s cumulative ' || case when meas = 'cases' then 'case count' else 'revenue (MTD cases × rate)' end ||
              ' minus the previous report date''s, summed over the location''s tracker rows; the first report date of the month shows its full MTD. Total = sum of the daily values (= MTD on the latest date). Projected target = the month''s ' ||
              case when meas = 'cases' then 'case target' else 'revenue target' end || '. Per day average = average over report dates.')
  into res;
  return res;
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
bs as (select max(snapshot_date) b from bi.zt_snapshot where snapshot_date < p_from and snapshot_date >= date_trunc('month', p_from)::date),
dr as (select location_label, client_label, jsonb_object_agg(snapshot_date, jsonb_strip_nulls(jsonb_build_object('mtd', mtd_cases, 'target', target_cases, 'rate', rate))) j
       from bi.zt_matrix_draft where snapshot_date between p_from and p_to and committed_batch is null and coalesce(mtd_cases, target_cases, rate) is not null group by 1, 2),
cm as (select location_label, client_label, jsonb_object_agg(snapshot_date, mtd_cases) j
       from bi.zt_row where row_type = 'leaf' and snapshot_date between p_from and p_to group by 1, 2),
rows as (select r.sheet_row, r.location_label, r.client_label, r.rate, r.target_cases, r.mtd_cases, r.zone_group, l.stakeholder, l.region, l.tier, dr.j drafts, cm.j committed,
                (select z.mtd_cases from bi.zt_row z, bs where z.snapshot_date = bs.b and z.row_type = 'leaf' and z.location_label = r.location_label and z.client_label = r.client_label limit 1) base
  from bi.zt_row r join tpl on r.snapshot_date = tpl.t left join bi.location l on l.id = r.location_id
  left join dr on dr.location_label = r.location_label and dr.client_label = r.client_label
  left join cm on cm.location_label = r.location_label and cm.client_label = r.client_label
  where r.row_type = 'leaf')
select jsonb_build_object(
  'template_snapshot', (select t from tpl), 'base_snapshot', (select b from bs),
  'dates', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('date', dt, 'status', status, 'info', info, 'control', control, 'reason', no_report_reason, 'reopen', reopen)) order by dt) from dates),
  'rows', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('r', sheet_row, 'zone', zone_group, 'location', location_label, 'client', client_label, 'stakeholder', stakeholder,
             'region', region, 'tier', tier, 'rate', rate, 'target', target_cases, 'last_mtd', mtd_cases, 'base', base, 'drafts', drafts, 'committed', committed)) order by sheet_row) from rows),
  'cadence_note', 'Expected dates = Monday–Saturday (observed tracker cadence) minus admin-marked no-report days. Rows and order come from the latest tracker snapshot on or before the end of the range.')
$fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''business_count''' in d) = 0 then
    d := replace(d, 'when ''branches'' then bi.api_branches(f)',
      'when ''branches'' then bi.api_branches(f)'||chr(10)||'      when ''business_count'' then bi.api_business_count(m, f, coalesce(p_args->>''measure'',''revenue''))');
    if position('''business_count''' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;

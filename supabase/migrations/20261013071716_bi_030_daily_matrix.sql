-- Applied to Supabase project via MCP on 20261013071716

create table if not exists bi.zt_matrix_draft (
  snapshot_date date not null, location_label text not null, client_label text not null,
  mtd_cases numeric, target_cases numeric, entered_by text not null, entered_at timestamptz not null default now(),
  primary key (snapshot_date, location_label, client_label));
create table if not exists bi.report_calendar_exception (report_date date primary key, reason text not null, set_by text, set_at timestamptz default now());
alter table bi.zt_matrix_draft enable row level security; alter table bi.report_calendar_exception enable row level security;

-- template = latest snapshot strictly before the date
create or replace function bi.matrix_template(p_date date) returns date language sql stable set search_path=bi,public as $$
  select max(snapshot_date) from bi.zt_snapshot where snapshot_date < p_date $$;

-- expected reporting dates: Mon–Sat (observed cadence) minus calendar exceptions
create or replace function bi.api_matrix(p_from date, p_to date) returns jsonb
language sql stable security definer set search_path=bi,public as $$
with d as (select g::date dt from generate_series(p_from, least(p_to, (now() at time zone 'Asia/Kolkata')::date), '1 day') g),
dates as (select dt,
   case when exists(select 1 from bi.zt_snapshot s where s.snapshot_date=dt) then 'loaded'
        when exists(select 1 from bi.report_calendar_exception e where e.report_date=dt) then 'no_report'
        when extract(isodow from dt)=7 then 'not_expected'
        when exists(select 1 from bi.zt_matrix_draft m where m.snapshot_date=dt) then 'draft'
        else 'missing' end status from d),
tpl as (select bi.matrix_template(coalesce((select min(dt) from dates where status in ('missing','draft')), p_to + 1)) t),
rows as (select r.location_label, r.client_label, r.location_id, r.client_code, r.rate, r.target_cases, r.mtd_cases, r.zone_group, l.stakeholder, l.region
  from bi.zt_row r join tpl on r.snapshot_date=tpl.t left join bi.location l on l.id=r.location_id where r.row_type='leaf')
select jsonb_build_object(
  'template_snapshot', (select t from tpl),
  'dates', (select jsonb_agg(jsonb_build_object('date',dt,'status',status) order by dt) from dates),
  'rows', (select jsonb_agg(jsonb_build_object('location',location_label,'client',client_label,'stakeholder',stakeholder,'zone',zone_group,'region',region,
       'rate',rate,'target',target_cases,'last_mtd',mtd_cases,
       'drafts',(select jsonb_object_agg(m.snapshot_date, jsonb_build_object('mtd',m.mtd_cases,'target',m.target_cases))
                 from bi.zt_matrix_draft m where m.location_label=rows.location_label and m.client_label=rows.client_label and m.snapshot_date between p_from and p_to))
       order by stakeholder nulls last, zone_group, location_label, client_label) from rows),
  'cadence_note','Expected dates = Monday–Saturday (observed tracker cadence) minus admin-marked no-report days.');
$$;

create or replace function bi.matrix_save(p_actor text, p jsonb) returns jsonb
language plpgsql security definer set search_path=bi,public as $$
declare n int;
begin
  insert into bi.zt_matrix_draft(snapshot_date, location_label, client_label, mtd_cases, target_cases, entered_by)
  select (c->>'date')::date, c->>'location', c->>'client', nullif(c->>'mtd','')::numeric, nullif(c->>'target','')::numeric, p_actor
  from jsonb_array_elements(p->'cells') c
  where not exists (select 1 from bi.zt_snapshot s where s.snapshot_date=(c->>'date')::date)
  on conflict (snapshot_date, location_label, client_label) do update
    set mtd_cases=coalesce(excluded.mtd_cases, bi.zt_matrix_draft.mtd_cases), target_cases=coalesce(excluded.target_cases, bi.zt_matrix_draft.target_cases),
        entered_by=excluded.entered_by, entered_at=now();
  get diagnostics n=row_count; return jsonb_build_object('saved', n);
end $$;

create or replace function bi.matrix_validate(p_date date) returns jsonb
language sql stable security definer set search_path=bi,public as $$
with t as (select bi.matrix_template(p_date) tpl),
leaf as (select r.* from bi.zt_row r, t where r.snapshot_date=t.tpl and r.row_type='leaf'),
dr as (select * from bi.zt_matrix_draft where snapshot_date=p_date),
same_month as (select date_trunc('month',(select tpl from t))=date_trunc('month',p_date) sm),
j as (select l.location_label, l.client_label, l.mtd_cases prev, d.mtd_cases cur, coalesce(d.target_cases, case when (select sm from same_month) then l.target_cases end) tgt
      from leaf l left join dr d using (location_label, client_label)),
chg as (select percentile_cont(0.9) within group (order by abs(mtd_cases - coalesce(src_prev_value,0))) p90
        from bi.zt_row, t where snapshot_date=t.tpl and row_type='leaf'),
issues as (
  select 'error' sev, 'missing_value' rule, location_label, client_label, null::numeric prev, null::numeric cur from j where cur is null
  union all select 'error','negative_value', location_label, client_label, prev, cur from j where cur < 0
  union all select 'warning','mtd_decreased', location_label, client_label, prev, cur from j, same_month where sm and cur < prev
  union all select 'warning','large_jump', location_label, client_label, prev, cur from j, same_month, chg
     where sm and cur - prev > greatest(25, 3*coalesce(chg.p90,0))
  union all select 'error','unknown_row', d.location_label, d.client_label, null, d.mtd_cases from dr d
     where not exists (select 1 from leaf l where l.location_label=d.location_label and l.client_label=d.client_label)
  union all select 'error','already_loaded', null, null, null, null where exists(select 1 from bi.zt_snapshot where snapshot_date=p_date))
select jsonb_build_object('date',p_date,'template',(select tpl from t),'same_month',(select sm from same_month),
  'rows_expected',(select count(*) from leaf),'rows_entered',(select count(*) from dr where mtd_cases is not null),
  'total_mtd',(select sum(cur) from j),'prev_total_mtd',(select sum(prev) from j),
  'errors',(select count(*) from issues where sev='error'),'warnings',(select count(*) from issues where sev='warning'),
  'issues',coalesce((select jsonb_agg(jsonb_build_object('severity',sev,'rule',rule,'location',location_label,'client',client_label,'previous',prev,'entered',cur)) from issues),'[]'::jsonb));
$$;

create or replace function bi.matrix_commit(p_actor text, p_date date, p_ack_warnings boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path=bi,public as $$
declare v jsonb := bi.matrix_validate(p_date); t date := bi.matrix_template(p_date); sm boolean; b bigint; h text;
begin
  if (v->>'errors')::int > 0 then return jsonb_build_object('committed',false,'reason','validation errors','validation',v); end if;
  if (v->>'warnings')::int > 0 and not coalesce(p_ack_warnings,false) then return jsonb_build_object('committed',false,'reason','warnings need acknowledgement','validation',v); end if;
  sm := date_trunc('month',t)=date_trunc('month',p_date);
  select md5(string_agg(location_label||'|'||client_label||'|'||coalesce(mtd_cases::text,'')||'|'||coalesce(target_cases::text,''),',' order by location_label,client_label))
    into h from bi.zt_matrix_draft where snapshot_date=p_date;
  insert into bi.import_batch(source_category,file_name,file_hash,period_month,snapshot_date,status,rows_in,rows_new,uploaded_by,committed_at,notes)
  values ('zonal','matrix:'||p_date,'matrix:'||p_date||':'||h,date_trunc('month',p_date)::date,p_date,'committed',(v->>'rows_entered')::int,(v->>'rows_entered')::int,p_actor,now(),
          'Daily matrix entry; template '||t||coalesce('; ack: '||p_reason,'')) returning id into b;
  insert into bi.zt_snapshot(snapshot_date,report_month,batch_id,file_name,pan_india_target,pan_india_mtd) values (p_date,date_trunc('month',p_date)::date,b,'matrix:'||p_date,0,0);
  insert into bi.zt_row(snapshot_date,sheet_row,row_type,zone_group,location_label,client_label,location_id,client_code,target_cases,mtd_cases,rate,
     revenue_target,revenue_actual,achievement,bd_revenue,shortfall_revenue,expense_projected,margin_after_expense,col_n_value,src_daily_value,src_prev_value)
  select p_date, r.sheet_row, r.row_type, r.zone_group, r.location_label, r.client_label, r.location_id, r.client_code,
     x.tgt, x.cur, r.rate, x.tgt*r.rate, x.cur*r.rate, x.cur/nullif(x.tgt,0), null, x.cur*r.rate - x.tgt*r.rate, null, null, null,
     x.cur - case when sm then r.mtd_cases else 0 end, case when sm then r.mtd_cases else 0 end
  from bi.zt_row r join lateral (select d.mtd_cases cur, coalesce(d.target_cases, case when sm then r.target_cases end) tgt
        from bi.zt_matrix_draft d where d.snapshot_date=p_date and d.location_label=r.location_label and d.client_label=r.client_label) x on true
  where r.snapshot_date=t and r.row_type='leaf';
  -- non-leaf rows: keep structure + expense; revenue recomputed from leaves (location block / zone)
  insert into bi.zt_row(snapshot_date,sheet_row,row_type,zone_group,location_label,client_label,expense_projected)
  select p_date, r.sheet_row, r.row_type, r.zone_group, r.location_label, r.client_label, r.expense_projected
  from bi.zt_row r where r.snapshot_date=t and r.row_type<>'leaf';
  update bi.zt_row z set revenue_actual = (select sum(l.revenue_actual) from bi.zt_row l where l.snapshot_date=p_date and l.row_type='leaf'
         and l.sheet_row < z.sheet_row and l.sheet_row > coalesce((select max(p.sheet_row) from bi.zt_row p where p.snapshot_date=p_date and p.row_type in ('location_total','zone_total') and p.sheet_row < z.sheet_row),0))
   where z.snapshot_date=p_date and z.row_type='location_total';
  update bi.zt_row z set revenue_actual = (select sum(l.revenue_actual) from bi.zt_row l where l.snapshot_date=p_date and l.row_type='leaf' and l.zone_group=z.zone_group)
   where z.snapshot_date=p_date and z.row_type='zone_total';
  update bi.zt_snapshot set pan_india_target=(select sum(target_cases) from bi.zt_row where snapshot_date=p_date and row_type='leaf'),
     pan_india_mtd=(select sum(mtd_cases) from bi.zt_row where snapshot_date=p_date and row_type='leaf') where snapshot_date=p_date;
  insert into bi.audit_log(actor,action,entity,entity_key,detail) values (p_actor,'matrix_commit','zt_snapshot',p_date::text,
     jsonb_build_object('batch',b,'template',t,'rows',v->'rows_entered','total_mtd',v->'total_mtd','prev_total_mtd',v->'prev_total_mtd','warnings',v->'warnings','ack_reason',p_reason,
       'values',(select jsonb_agg(jsonb_build_object('l',location_label,'c',client_label,'mtd',mtd_cases,'target',target_cases,'by',entered_by)) from bi.zt_matrix_draft where snapshot_date=p_date)));
  delete from bi.zt_matrix_draft where snapshot_date=p_date;
  return jsonb_build_object('committed',true,'batch',b,'snapshot',p_date,'total_mtd',v->'total_mtd','rows',v->'rows_entered');
end $$;

create or replace function bi.matrix_mark_no_report(p_actor text, p_date date, p_reason text) returns jsonb
language sql security definer set search_path=bi,public as $$
  insert into bi.report_calendar_exception(report_date,reason,set_by) values (p_date,p_reason,p_actor)
  on conflict (report_date) do update set reason=excluded.reason, set_by=excluded.set_by, set_at=now()
  returning jsonb_build_object('date',report_date,'reason',reason) $$;

revoke all on function bi.api_matrix(date,date), bi.matrix_save(text,jsonb), bi.matrix_validate(date), bi.matrix_commit(text,date,boolean,text), bi.matrix_mark_no_report(text,date,text) from public, anon, authenticated;

create or replace function public.bi_admin(p_action text, p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if not bi.admin_ok(p->>'admin_key') then raise exception 'admin key required' using errcode='42501'; end if;
  case p_action
    when 'verify' then return jsonb_build_object('ok', true);
    when 'mapping_update' then return bi.api_mapping_update('admin-key', p - 'admin_key');
    when 'refresh_employees' then
      insert into bi.audit_log(actor,action,entity) values ('admin-key','request_refresh','point_derived');
      return jsonb_build_object('queued', true, 'note', 'Classification and Force1 figures refresh within 10 minutes');
    when 'matrix' then return bi.api_matrix((p->>'from')::date, (p->>'to')::date);
    when 'matrix_save' then return bi.matrix_save('admin-key', p);
    when 'matrix_validate' then return bi.matrix_validate((p->>'date')::date);
    when 'matrix_commit' then return bi.matrix_commit('admin-key', (p->>'date')::date, coalesce((p->>'ack')::boolean,false), p->>'reason');
    when 'matrix_no_report' then return bi.matrix_mark_no_report('admin-key', (p->>'date')::date, p->>'reason');
    else raise exception 'unknown action';
  end case;
end $$;
grant execute on function public.bi_admin(text, jsonb) to anon, authenticated;


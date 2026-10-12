-- Applied to Supabase project via MCP on 20261012050953

create extension if not exists pg_trgm with schema extensions;

-- history keyed on resolved entities (labels drift between snapshots)
drop table bi.zt_month_history;
create table bi.zt_month_history (
  month date not null, location_id int not null references bi.location(id), client_code text not null references bi.client(code),
  cases numeric, revenue numeric, billing numeric,
  source_snapshot date not null, source_columns text,
  primary key (month, location_id, client_code)
);
alter table bi.zt_month_history enable row level security;

create table bi.group_precedence (group_a text, group_b text, winner text not null, rule text not null, primary key(group_a, group_b));
alter table bi.group_precedence enable row level security;

create or replace function bi.norm(t text) returns text language sql immutable as
$$ select nullif(upper(regexp_replace(trim(coalesce(t,'')), '\s+', ' ', 'g')), '') $$;
create or replace function bi.norm_gj(t text) returns text language sql immutable as   -- undo the observed G->J corruption
$$ select replace(bi.norm(t), 'J', 'G') $$;

create or replace function bi.current_email() returns text language sql stable as
$$ select lower(coalesce(auth.jwt()->>'email','')) $$;
create or replace function bi.app_role() returns text language sql stable security definer set search_path = bi, public as
$$ select role from bi.app_user where email = bi.current_email() and active
     and coalesce((auth.jwt()->>'email_verified')::boolean, (auth.jwt()->'user_metadata'->>'email_verified')::boolean, true) $$;
create or replace function bi.token_ok(p_token text) returns boolean language sql stable security definer set search_path = bi, public, extensions as
$$ select p_token is not null and exists(select 1 from bi.ingest_token where token_hash = encode(extensions.digest(p_token,'sha256'),'hex') and not revoked and expires_at > now()) $$;

create or replace function bi.status_rank(s text) returns int language sql immutable as
$$ select case upper(coalesce(s,'')) when 'COMPLETED' then 3 when 'REVIEWED' then 2 when 'IN PROGRESS' then 2 when 'ASSIGNED' then 1 else 0 end $$;

-- ---------- location / client resolution ----------
create or replace function bi.resolve_location(p_label text, p_zone text, p_batch bigint) returns int
language plpgsql security definer set search_path = bi, public, extensions as $$
declare v_id int; v_sim numeric; v_alias text := bi.norm(p_label);
begin
  if v_alias is null then return null; end if;
  select location_id into v_id from bi.location_alias where source='zonal_label' and alias=v_alias and review_status <> 'rejected';
  if found then return v_id; end if;
  -- rule 1: G->J corruption (observed 2026-07-06)
  select la.location_id into v_id from bi.location_alias la
   where la.source='zonal_label' and la.review_status <> 'rejected' and bi.norm_gj(la.alias) = bi.norm_gj(p_label) limit 1;
  if found then
    insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
    values ('zonal_label',v_alias,v_id,'g_j_typo_normalisation',0.95,jsonb_build_object('batch',p_batch,'zone',p_zone),'auto');
    return v_id;
  end if;
  -- rule 2: trigram similarity against known aliases
  select la.location_id, similarity(la.alias, v_alias) into v_id, v_sim from bi.location_alias la
   where la.source='zonal_label' and la.review_status <> 'rejected' order by similarity(la.alias, v_alias) desc limit 1;
  if v_sim >= 0.6 then
    insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
    values ('zonal_label',v_alias, case when v_sim>=0.85 then v_id end,'trigram',round(v_sim,3),
            jsonb_build_object('batch',p_batch,'zone',p_zone,'candidate_location_id',v_id),
            case when v_sim>=0.85 then 'auto' else 'needs_review' end);
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'zonal',p_label,'location_alias_auto_matched', case when v_sim>=0.85 then 'info' else 'warning' end,
            jsonb_build_object('candidate_location_id',v_id,'similarity',round(v_sim,3)));
    return case when v_sim>=0.85 then v_id end;
  end if;
  -- rule 3: genuinely new tracker location (tracker is authoritative) -> create, flag for review
  insert into bi.location(code,label,zone_group) values (v_alias,p_label,null) returning id into v_id;
  insert into bi.location_alias(source,alias,location_id,method,confidence,evidence,review_status)
  values ('zonal_label',v_alias,v_id,'new_from_tracker',1,jsonb_build_object('batch',p_batch,'zone',p_zone),'needs_review');
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
  values (p_batch,'zonal',p_label,'new_location_created','warning',jsonb_build_object('location_id',v_id,'zone',p_zone));
  return v_id;
end $$;

create or replace function bi.resolve_client(p_source text, p_label text, p_batch bigint) returns text
language plpgsql security definer set search_path = bi, public as $$
declare v text; a text := bi.norm(p_label);
begin
  if a is null then return null; end if;
  select client_code into v from bi.client_alias where source=p_source and alias=a and review_status<>'rejected';
  if found then return v; end if;
  select client_code into v from bi.client_alias where source=p_source and bi.norm_gj(alias)=bi.norm_gj(a) and review_status<>'rejected' limit 1;
  if found then
    insert into bi.client_alias values (p_source,a,v,'g_j_typo_normalisation',0.95,'auto'); return v;
  end if;
  v := regexp_replace(a,'[^A-Z0-9]+','_','g');
  insert into bi.client(code,label,family) values (v,p_label,v) on conflict do nothing;
  insert into bi.client_alias values (p_source,a,v,'new_unmapped',1,'needs_review') on conflict do nothing;
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
  values (p_batch,p_source,p_label,'new_client_created','warning',jsonb_build_object('client_code',v));
  return v;
end $$;

-- ---------- commit: Case Wise ----------
create or replace function bi.commit_case(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare b bi.import_batch; v_unit text; v_unit_loc int; r jsonb;
begin
  select * into b from bi.import_batch where id=p_batch for update;
  select recon_unit into v_unit from bi.location_alias where source='case_file' and alias=bi.norm(b.location_group);
  if v_unit is null then
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'case',b.location_group,'unmapped_case_file_group','error','{}');
  end if;
  select case when count(*)=1 then min(id) end into v_unit_loc from bi.location where recon_unit=v_unit;

  create temp table _n on commit drop as
  select distinct on (case_id) * from (
    select s.seq, (p->>'case_id')::bigint case_id, p->>'client' client_raw,
      bi.resolve_client('case', p->>'client', p_batch) client_code,
      p->>'branch' branch, p->>'branch_code' branch_code, p->>'branch_type' branch_type, nullif(p->>'area_office','-') area_office,
      p->>'status' status, (p->>'received_at')::timestamptz received_at, (p->>'completed_at')::timestamptz completed_at,
      (p->>'due_at')::timestamptz due_at, nullif(p->>'product','-') product, nullif(p->>'points','')::int points_declared,
      md5((p - '_src_row')::text) row_hash
    from bi.stg_row s, lateral (select s.payload p) x
    where s.batch_id=p_batch and (p->>'case_id') ~ '^\d+$') q
  order by case_id, seq desc;

  -- branch-level location (rules seeded in location_alias source='branch'/'area_office')
  alter table _n add column location_id int;
  update _n set location_id = coalesce(
      (select la.location_id from bi.location_alias la where la.source='area_office' and la.alias=bi.norm(_n.area_office) and la.recon_unit=v_unit and la.review_status<>'rejected'),
      (select la.location_id from bi.location_alias la where la.source='branch_token' and la.recon_unit=v_unit and la.review_status<>'rejected'
         and bi.norm(_n.branch) like '%'||la.alias||'%' order by length(la.alias) desc limit 1),
      v_unit_loc);

  with ex as (select n.*, c.case_id ex_id, c.row_hash ex_hash, c.file_group ex_group, c.status ex_status, c.completed_at ex_completed
              from _n n left join bi.fact_case c using (case_id)),
  cls as (select *, case when ex_id is null then 'new' when ex_hash=row_hash then 'unchanged'
                         when ex_group = b.location_group then 'changed'
                         when bi.status_rank(status) > bi.status_rank(ex_status)
                           or (bi.status_rank(status) = bi.status_rank(ex_status) and coalesce(completed_at,'-infinity') >= coalesce(ex_completed,'-infinity')) then 'cross_file_replace'
                         else 'cross_file_keep' end k from ex),
  dq as (insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
         select p_batch,'case',case_id::text,'case_in_multiple_location_files','info',
                jsonb_build_object('existing_group',ex_group,'new_group',b.location_group,'action',k)
         from cls where k like 'cross_file%' returning 1),
  up as (insert into bi.fact_case as t(case_id,client_raw,client_code,branch,branch_code,branch_type,area_office,status,received_at,completed_at,due_at,product,points_declared,file_group,recon_unit,location_id,row_hash,first_batch,last_batch)
         select case_id,client_raw,client_code,branch,branch_code,branch_type,area_office,status,received_at,completed_at,due_at,product,points_declared,
                coalesce((select winner from bi.group_precedence g where (g.group_a,g.group_b) in ((ex_group,b.location_group),(b.location_group,ex_group))), b.location_group),
                null, location_id, row_hash, p_batch, p_batch
         from cls where k in ('new','changed','cross_file_replace','unchanged')
         on conflict (case_id) do update set
           client_raw=excluded.client_raw, client_code=excluded.client_code, branch=excluded.branch, branch_code=excluded.branch_code,
           branch_type=excluded.branch_type, area_office=excluded.area_office, status=excluded.status, received_at=excluded.received_at,
           completed_at=excluded.completed_at, due_at=excluded.due_at, product=excluded.product, points_declared=excluded.points_declared,
           file_group=excluded.file_group, location_id=coalesce(excluded.location_id,t.location_id), row_hash=excluded.row_hash,
           last_batch=excluded.last_batch, updated_at=now()
         returning 1)
  select jsonb_build_object('rows_in',(select count(*) from bi.stg_row where batch_id=p_batch),
     'distinct',(select count(*) from cls),
     'new',count(*) filter (where k='new'),'changed',count(*) filter (where k in ('changed','cross_file_replace')),
     'unchanged',count(*) filter (where k in ('unchanged','cross_file_keep')),'cross_file',count(*) filter (where k like 'cross_file%'),
     'upserted',(select count(*) from up),'dq',(select count(*) from dq)) into r from cls;
  -- recon unit follows the (possibly precedence-adjusted) file group
  update bi.fact_case c set recon_unit = la.recon_unit,
         location_id = coalesce(c.location_id, (select case when count(*)=1 then min(id) end from bi.location l where l.recon_unit=la.recon_unit))
    from bi.location_alias la where la.source='case_file' and la.alias=bi.norm(c.file_group) and c.last_batch=p_batch;
  update bi.import_batch set status='committed', committed_at=now(), rows_in=(r->>'rows_in')::int, rows_new=(r->>'new')::int,
         rows_changed=(r->>'changed')::int, rows_unchanged=(r->>'unchanged')::int,
         rows_rejected=(r->>'rows_in')::int-(r->>'distinct')::int where id=p_batch;
  delete from bi.stg_row where batch_id=p_batch;
  return r;
end $$;

-- ---------- commit: Point Wise ----------
create or replace function bi.commit_point(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare b bi.import_batch; v_unit text; r jsonb;
begin
  select * into b from bi.import_batch where id=p_batch for update;
  select recon_unit into v_unit from bi.location_alias where source='case_file' and alias=bi.norm(b.location_group);
  create temp table _p on commit drop as
  select distinct on (point_id) * from (
    select s.seq, (p->>'point_id')::bigint point_id, (p->>'case_id')::bigint case_id, p->>'branch' branch, p->>'client_code' client_code_raw,
      p->>'branch_type' branch_type, nullif(p->>'area_office','-') area_office, nullif(p->>'user_type','-') user_type, p->>'point_type' point_type,
      bi.norm(p->>'created_by') created_by, (p->>'created_at')::timestamptz created_at, bi.norm(p->>'assign_to') assign_to,
      p->>'status' status, p->>'report_status' report_status, bi.norm(p->>'verified_by') verified_by, bi.norm(p->>'completed_by') completed_by,
      (p->>'assigned_at')::timestamptz assigned_at, (p->>'field_reviewed_at')::timestamptz field_reviewed_at, (p->>'completed_at')::timestamptz completed_at,
      case when p->>'pincode' ~ '^\d{6}$' then p->>'pincode' end pincode, (p->>'has_address')::boolean has_address, nullif(p->>'product','-') product,
      md5((p - '_src_row')::text) row_hash
    from bi.stg_row s, lateral (select s.payload p) x
    where s.batch_id=p_batch and (p->>'point_id') ~ '^\d+$' and (p->>'case_id') ~ '^\d+$') q
  order by point_id, seq desc;
  with ex as (select n.*, c.point_id ex_id, c.row_hash ex_hash, c.file_group ex_group, c.status ex_status from _p n left join bi.fact_point c using (point_id)),
  cls as (select *, case when ex_id is null then 'new' when ex_hash=row_hash then 'unchanged' when ex_group=b.location_group then 'changed'
                         when bi.status_rank(status) >= bi.status_rank(ex_status) then 'cross_file_replace' else 'cross_file_keep' end k from ex),
  dq as (insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
         select p_batch,'point',point_id::text,'point_in_multiple_location_files','info',jsonb_build_object('existing_group',ex_group,'new_group',b.location_group,'action',k)
         from cls where k like 'cross_file%' returning 1),
  up as (insert into bi.fact_point as t(point_id,case_id,branch,client_code_raw,branch_type,area_office,user_type,point_type,created_by,created_at,assign_to,status,report_status,verified_by,completed_by,assigned_at,field_reviewed_at,completed_at,pincode,has_address,product,file_group,recon_unit,row_hash,first_batch,last_batch)
         select point_id,case_id,branch,client_code_raw,branch_type,area_office,user_type,point_type,created_by,created_at,assign_to,status,report_status,verified_by,completed_by,assigned_at,field_reviewed_at,completed_at,pincode,has_address,product,
                coalesce((select winner from bi.group_precedence g where (g.group_a,g.group_b) in ((ex_group,b.location_group),(b.location_group,ex_group))), b.location_group),
                null,row_hash,p_batch,p_batch
         from cls where k in ('new','changed','cross_file_replace','unchanged')
         on conflict (point_id) do update set case_id=excluded.case_id, branch=excluded.branch, client_code_raw=excluded.client_code_raw, branch_type=excluded.branch_type,
           area_office=excluded.area_office, user_type=excluded.user_type, point_type=excluded.point_type, created_by=excluded.created_by, created_at=excluded.created_at,
           assign_to=excluded.assign_to, status=excluded.status, report_status=excluded.report_status, verified_by=excluded.verified_by, completed_by=excluded.completed_by,
           assigned_at=excluded.assigned_at, field_reviewed_at=excluded.field_reviewed_at, completed_at=excluded.completed_at, pincode=excluded.pincode,
           has_address=excluded.has_address, product=excluded.product, file_group=excluded.file_group, row_hash=excluded.row_hash, last_batch=excluded.last_batch, updated_at=now()
         returning 1)
  select jsonb_build_object('rows_in',(select count(*) from bi.stg_row where batch_id=p_batch),'distinct',(select count(*) from cls),
     'new',count(*) filter (where k='new'),'changed',count(*) filter (where k in ('changed','cross_file_replace')),
     'unchanged',count(*) filter (where k in ('unchanged','cross_file_keep')),'upserted',(select count(*) from up),'dq',(select count(*) from dq)) into r from cls;
  update bi.fact_point p set recon_unit = la.recon_unit from bi.location_alias la where la.source='case_file' and la.alias=bi.norm(p.file_group) and p.last_batch=p_batch;
  insert into bi.point_type(name,category,rule,review_status)
    select distinct point_type,'unknown','new point type seen in upload','needs_review' from bi.fact_point where last_batch=p_batch and point_type is not null
    on conflict do nothing;
  update bi.import_batch set status='committed', committed_at=now(), rows_in=(r->>'rows_in')::int, rows_new=(r->>'new')::int,
         rows_changed=(r->>'changed')::int, rows_unchanged=(r->>'unchanged')::int, rows_rejected=(r->>'rows_in')::int-(r->>'distinct')::int where id=p_batch;
  delete from bi.stg_row where batch_id=p_batch;
  return r;
end $$;

-- ---------- commit: Zonal tracker snapshot ----------
create or replace function bi.commit_zonal(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare b bi.import_batch; h jsonb; v_snap date; v_month date; v_leaf_t numeric; v_leaf_m numeric; v_rows int; v_hist int := 0;
begin
  select * into b from bi.import_batch where id=p_batch for update;
  select payload into h from bi.stg_row where batch_id=p_batch and seq=0;
  v_snap := (h->>'snapshot_date')::date; v_month := (h->>'report_month')::date;
  if v_snap is null or v_month is null then raise exception 'zonal batch % lacks snapshot_date/report_month', p_batch; end if;
  if v_snap < date '2024-04-01' then raise exception 'snapshot % predates analytical cutoff 2024-04-01', v_snap; end if;
  update bi.import_batch set status='superseded' where id in (select batch_id from bi.zt_snapshot where snapshot_date=v_snap) and id<>p_batch;
  delete from bi.zt_snapshot where snapshot_date=v_snap;   -- cascade removes rows of the replaced version (batch kept in import_batch)
  insert into bi.zt_snapshot(snapshot_date,report_month,batch_id,file_name,pan_india_target,pan_india_mtd)
  values (v_snap,v_month,p_batch,b.file_name,(h#>>'{control,target}')::numeric,(h#>>'{control,mtd}')::numeric);

  insert into bi.zt_row(snapshot_date,sheet_row,row_type,zone_group,location_label,client_label,location_id,client_code,target_cases,mtd_cases,rate,
     revenue_target,revenue_actual,achievement,bd_revenue,shortfall_revenue,expense_projected,margin_after_expense,col_n_value,src_daily_value,src_prev_value)
  select v_snap,(p->>'sheet_row')::int,p->>'row_type',p->>'zone_group',p->>'location_label',p->>'client_label',
     case when p->>'row_type' in ('leaf','zone_client_rollup','location_total') then bi.resolve_location(p->>'location_label',p->>'zone_group',p_batch) end,
     case when p->>'row_type' in ('leaf','zone_client_rollup') then bi.resolve_client('zonal',p->>'client_label',p_batch) end,
     (p->>'target_cases')::numeric,(p->>'mtd_cases')::numeric,(p->>'rate')::numeric,(p->>'revenue_target')::numeric,(p->>'revenue_actual')::numeric,
     (p->>'achievement')::numeric,(p->>'bd_revenue')::numeric,(p->>'shortfall_revenue')::numeric,(p->>'expense_projected')::numeric,
     (p->>'margin_after_expense')::numeric,(p->>'col_n_value')::numeric,(p->>'src_daily_value')::numeric,(p->>'src_prev_value')::numeric
  from bi.stg_row s, lateral (select s.payload p) x where s.batch_id=p_batch and s.seq>0
  order by s.seq;   -- deterministic alias creation
  get diagnostics v_rows = row_count;

  -- monthly history (closed months only, >= 2024-04, newer snapshot wins)
  insert into bi.zt_month_history as t(month,location_id,client_code,cases,revenue,billing,source_snapshot,source_columns)
  select make_date((e->>'y')::int,(e->>'m')::int,1), z.location_id, z.client_code,
         sum((e->>'v')::numeric) filter (where e->>'k'='cases'), sum((e->>'v')::numeric) filter (where e->>'k'='revenue'),
         sum((e->>'v')::numeric) filter (where e->>'k'='billing'), v_snap, string_agg(distinct e->>'c', ',')
  from bi.stg_row s
  join bi.zt_row z on z.snapshot_date=v_snap and z.sheet_row=(s.payload->>'sheet_row')::int and z.row_type='leaf'
  cross join lateral jsonb_array_elements(coalesce(s.payload->'history','[]')) e
  where s.batch_id=p_batch and z.location_id is not null
    and make_date((e->>'y')::int,(e->>'m')::int,1) between date '2024-04-01' and (v_month - interval '1 month')
  group by 1,2,3
  on conflict (month,location_id,client_code) do update set cases=excluded.cases, revenue=excluded.revenue, billing=excluded.billing,
     source_snapshot=excluded.source_snapshot, source_columns=excluded.source_columns
  where excluded.source_snapshot >= t.source_snapshot;
  get diagnostics v_hist = row_count;

  -- control-total reconciliation against the source's own Pan India row
  select sum(target_cases), sum(mtd_cases) into v_leaf_t, v_leaf_m from bi.zt_row where snapshot_date=v_snap and row_type='leaf';
  if (h->'control') is not null and (abs(coalesce(v_leaf_t,0)-coalesce((h#>>'{control,target}')::numeric,0))>0.5 or abs(coalesce(v_leaf_m,0)-coalesce((h#>>'{control,mtd}')::numeric,0))>0.5) then
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
    values (p_batch,'zonal',v_snap::text,'source_total_mismatch','warning',
      jsonb_build_object('leaf_target',v_leaf_t,'source_target',h#>>'{control,target}','leaf_mtd',v_leaf_m,'source_mtd',h#>>'{control,mtd}','authority','leaf rows'));
  end if;
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
  select p_batch,'zonal',v_snap::text,i->>'rule',coalesce(i->>'severity','info'),i->'detail' from jsonb_array_elements(coalesce(h->'issues','[]')) i;

  update bi.import_batch set status='committed', committed_at=now(), rows_in=v_rows, rows_new=v_rows, snapshot_date=v_snap, period_month=v_month where id=p_batch;
  delete from bi.stg_row where batch_id=p_batch;
  return jsonb_build_object('snapshot',v_snap,'rows',v_rows,'history_upserts',v_hist,'leaf_target',v_leaf_t,'leaf_mtd',v_leaf_m);
end $$;

-- ---------- single API entry point for ingestion ----------
create or replace function public.bi_ingest(p_token text, p_action text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare v_actor text; v_id bigint; v_dup bigint; r jsonb; v_cat text;
begin
  if bi.token_ok(p_token) then v_actor := 'loader-token';
  elsif bi.app_role() = 'admin' then v_actor := bi.current_email();
  else raise exception 'not authorised' using errcode = '42501'; end if;

  if p_action = 'begin' then
    select id into v_dup from bi.import_batch where file_hash = p_payload->>'file_hash' and status='committed';
    if v_dup is not null and coalesce((p_payload->>'force')::boolean,false) is false then
      return jsonb_build_object('duplicate',true,'batch_id',v_dup);
    end if;
    insert into bi.import_batch(source_category,file_name,file_hash,location_group,period_month,snapshot_date,uploaded_by,notes)
    values (p_payload->>'category',p_payload->>'file_name',p_payload->>'file_hash',p_payload->>'location_group',
            nullif(p_payload->>'period_month','')::date,nullif(p_payload->>'snapshot_date','')::date,v_actor,p_payload->>'notes')
    returning id into v_id;
    if v_dup is not null then update bi.import_batch set status='superseded' where id=v_dup; end if;
    insert into bi.audit_log(actor,action,entity,entity_key,detail) values (v_actor,'import_begin','import_batch',v_id::text,p_payload - 'rows');
    return jsonb_build_object('batch_id',v_id);
  elsif p_action = 'stage' then
    v_id := (p_payload->>'batch_id')::bigint;
    if not exists(select 1 from bi.import_batch where id=v_id and status='staged') then raise exception 'batch % not stageable', v_id; end if;
    insert into bi.stg_row(batch_id,seq,payload)
    select v_id, (p_payload->>'seq_start')::int + o - 1, e from jsonb_array_elements(p_payload->'rows') with ordinality t(e,o)
    on conflict (batch_id,seq) do update set payload=excluded.payload;
    return jsonb_build_object('staged', jsonb_array_length(p_payload->'rows'));
  elsif p_action = 'commit' then
    v_id := (p_payload->>'batch_id')::bigint;
    select source_category into v_cat from bi.import_batch where id=v_id and status='staged';
    if v_cat is null then raise exception 'batch % not staged', v_id; end if;
    r := case v_cat when 'case' then bi.commit_case(v_id) when 'point' then bi.commit_point(v_id) else bi.commit_zonal(v_id) end;
    insert into bi.audit_log(actor,action,entity,entity_key,detail) values (v_actor,'import_commit','import_batch',v_id::text,r);
    return r;
  elsif p_action = 'reject' then
    update bi.import_batch set status='rejected', notes=coalesce(notes,'')||' '||coalesce(p_payload->>'reason','') where id=(p_payload->>'batch_id')::bigint and status='staged';
    delete from bi.stg_row where batch_id=(p_payload->>'batch_id')::bigint;
    return jsonb_build_object('rejected',true);
  end if;
  raise exception 'unknown action %', p_action;
end $$;
revoke all on function public.bi_ingest(text,text,jsonb) from public;
grant execute on function public.bi_ingest(text,text,jsonb) to anon, authenticated;


-- Applied to Supabase project via MCP on 20261012103004

create temp table _vd on commit drop as
select v, pg_get_viewdef(v::regclass) def, ord from (values ('bi.v_case',1),('bi.v_point',2),('bi.v_force_usage',3)) t(v,ord);
drop view bi.v_force_usage; drop view bi.v_case; drop view bi.v_point;
drop table bi.fact_case; drop table bi.fact_point;

create index on bi.case_store(received_month, recon_unit, client_code);
create index on bi.case_store(location_id);
create index on bi.point_store(case_id);
create index on bi.point_store(created_month, recon_unit);
create index on bi.point_store(verified_by_id);

-- Compatibility views: same names/columns the readers use, decoded from the compact stores
create view bi.fact_case as
select s.case_id, s.client_code, b.val branch, s.branch_code, ao.val area_office, s.status, s.received_at, s.completed_at, s.due_at,
       pr.val product, s.points_declared::int points_declared, s.file_group, s.recon_unit, s.location_id, s.received_month, s.row_hash, s.last_batch
from bi.case_store s left join bi.dim b on b.id=s.branch_id left join bi.dim ao on ao.id=s.area_office_id left join bi.dim pr on pr.id=s.product_id;
create view bi.fact_point as
select s.point_id, s.case_id, b.val branch, s.client_code_raw, t.val point_type, cb.val created_by, s.created_at, a.val assign_to, s.status,
       v.val verified_by, cp.val completed_by, s.assigned_at, s.field_reviewed_at, s.completed_at, s.pincode::text pincode, s.has_address,
       s.file_group, s.recon_unit, s.created_month, s.row_hash, s.last_batch
from bi.point_store s left join bi.dim b on b.id=s.branch_id left join bi.dim t on t.id=s.point_type_id left join bi.dim cb on cb.id=s.created_by_id
left join bi.dim a on a.id=s.assign_to_id left join bi.dim v on v.id=s.verified_by_id left join bi.dim cp on cp.id=s.completed_by_id;

-- Recreate dependent views; v_point gets the business route rule (12-Oct-2026)
do $$ declare r record; d text; i1 int; i2 int; m text := $m$THEN 'back_office_update_likely_outside_force'::text$m$;
begin
  for r in select * from _vd order by ord loop
    d := r.def;
    if r.v = 'bi.v_point' then
      i1 := position('WHEN (p.assign_to IS NULL)' in d); i2 := position(m in d);
      if i1 = 0 or i2 = 0 then raise exception 'route CASE not found in v_point'; end if;
      d := substr(d,1,i1-1) || $x$WHEN (p.verified_by IS NULL) THEN 'unknown_not_verified'::text
            WHEN (ev.classification = 'field_executive'::text) THEN 'in_force_by_field_executive'::text
            WHEN (ev.classification = ANY (ARRAY['back_office'::text, 'mixed'::text])) THEN 'back_office_update_likely_outside_force'::text$x$ || substr(d, i2 + length(m));
    end if;
    execute format('create view %s as %s', r.v, d);
  end loop;
end $$;

create or replace function bi.commit_case(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare b bi.import_batch; v_unit text; v_unit_loc int; r jsonb;
begin
  select * into b from bi.import_batch where id=p_batch for update;
  select recon_unit into v_unit from bi.location_alias where source='case_file' and alias=bi.norm(b.location_group);
  if v_unit is null then
    insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail) values (p_batch,'case',b.location_group,'unmapped_case_file_group','error','{}');
  end if;
  select case when count(*)=1 then min(id) end into v_unit_loc from bi.location where recon_unit=v_unit;
  create temp table _n on commit drop as
  select distinct on (case_id) * from (
    select s.seq, (p->>'case_id')::bigint case_id, bi.resolve_client('case', p->>'client', p_batch) client_code,
      p->>'branch' branch, nullif(p->>'branch_code','') branch_code, nullif(p->>'area_office','-') area_office,
      p->>'status' status, (p->>'received_at')::timestamptz received_at, (p->>'completed_at')::timestamptz completed_at,
      (p->>'due_at')::timestamptz due_at, nullif(p->>'product','-') product, nullif(p->>'points','')::int points_declared,
      hashtextextended(md5((p - '_src_row')::text),0) row_hash
    from bi.stg_row s, lateral (select s.payload p) x
    where s.batch_id=p_batch and (p->>'case_id') ~ '^\d+$') q
  order by case_id, seq desc;
  alter table _n add column location_id int;
  update _n set location_id = coalesce(
      (select la.location_id from bi.location_alias la where la.source='area_office' and la.alias=bi.norm(_n.area_office) and la.recon_unit=v_unit and la.review_status<>'rejected'),
      (select la.location_id from bi.location_alias la where la.source='branch_token' and la.recon_unit=v_unit and la.review_status<>'rejected'
         and bi.norm(_n.branch) like '%'||la.alias||'%' order by length(la.alias) desc limit 1),
      v_unit_loc) where true;
  with ex as (select n.*, c.case_id ex_id, c.row_hash ex_hash, c.file_group ex_group, c.status ex_status, c.completed_at ex_completed
              from _n n left join bi.case_store c using (case_id)),
  cls as (select *, case when ex_id is null then 'new' when ex_hash=row_hash then 'unchanged'
                         when ex_group = b.location_group then 'changed'
                         when bi.status_rank(status) > bi.status_rank(ex_status)
                           or (bi.status_rank(status) = bi.status_rank(ex_status) and coalesce(completed_at,'-infinity') >= coalesce(ex_completed,'-infinity')) then 'cross_file_replace'
                         else 'cross_file_keep' end k from ex),
  dq as (insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
         select p_batch,'case',case_id::text,'case_in_multiple_location_files','info',jsonb_build_object('existing_group',ex_group,'new_group',b.location_group,'action',k)
         from cls where k like 'cross_file%' returning 1),
  up as (insert into bi.case_store as t(case_id,client_code,branch_id,branch_code,area_office_id,status,received_at,completed_at,due_at,product_id,points_declared,file_group,recon_unit,location_id,row_hash,last_batch)
         select case_id,client_code,bi.dim_id('branch',branch),branch_code,bi.dim_id('area_office',area_office),status,received_at,completed_at,due_at,
                bi.dim_id('product',product),points_declared,
                coalesce((select winner from bi.group_precedence g where (g.group_a,g.group_b) in ((ex_group,b.location_group),(b.location_group,ex_group))), b.location_group),
                null, location_id, row_hash, p_batch
         from cls where k in ('new','changed','cross_file_replace','unchanged')
         on conflict (case_id) do update set client_code=excluded.client_code, branch_id=excluded.branch_id, branch_code=excluded.branch_code,
           area_office_id=excluded.area_office_id, status=excluded.status, received_at=excluded.received_at, completed_at=excluded.completed_at,
           due_at=excluded.due_at, product_id=excluded.product_id, points_declared=excluded.points_declared, file_group=excluded.file_group,
           location_id=coalesce(excluded.location_id,t.location_id), row_hash=excluded.row_hash, last_batch=excluded.last_batch
         returning 1)
  select jsonb_build_object('rows_in',(select count(*) from bi.stg_row where batch_id=p_batch),'distinct',(select count(*) from cls),
     'new',count(*) filter (where k='new'),'changed',count(*) filter (where k in ('changed','cross_file_replace')),
     'unchanged',count(*) filter (where k in ('unchanged','cross_file_keep')),'cross_file',count(*) filter (where k like 'cross_file%'),
     'upserted',(select count(*) from up),'dq',(select count(*) from dq)) into r from cls;
  update bi.case_store c set recon_unit = la.recon_unit,
         location_id = coalesce(c.location_id, (select case when count(*)=1 then min(id) end from bi.location l where l.recon_unit=la.recon_unit))
    from bi.location_alias la where la.source='case_file' and la.alias=bi.norm(c.file_group) and c.case_id in (select case_id from _n);
  update bi.import_batch set rows_in=rows_in+(r->>'rows_in')::int, rows_new=rows_new+(r->>'new')::int,
         rows_changed=rows_changed+(r->>'changed')::int, rows_unchanged=rows_unchanged+(r->>'unchanged')::int,
         rows_rejected=rows_rejected+(r->>'rows_in')::int-(r->>'distinct')::int where id=p_batch;
  perform bi.relocate_cases(p_batch);
  delete from bi.stg_row where batch_id=p_batch;
  return r;
end $$;

create or replace function bi.relocate_cases(p_batch bigint) returns integer
language plpgsql security definer set search_path = bi, public as $$
declare n int;
begin
  update bi.case_store c set recon_unit = u.recon_unit,
    location_id = coalesce(
      (select la.location_id from bi.location_alias la where la.source='area_office' and la.recon_unit=u.recon_unit and la.review_status<>'rejected'
         and la.alias=bi.norm((select val from bi.dim where id=c.area_office_id))),
      (select la.location_id from bi.location_alias la where la.source='branch_token' and la.recon_unit=u.recon_unit and la.review_status<>'rejected'
         and bi.norm((select val from bi.dim where id=c.branch_id)) ~ ('(^|[^A-Z])'||la.alias||'([^A-Z]|$)') order by length(la.alias) desc limit 1),
      (select l.id from bi.location l where l.recon_unit=u.recon_unit and l.is_unit_default))
  from bi.location_alias u where u.source='case_file' and u.alias=bi.norm(c.file_group) and c.case_id in (select case_id from _n);
  get diagnostics n = row_count;
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
  select p_batch,'case',c.branch,'branch_outside_file_unit','info',jsonb_build_object('file_unit',c.recon_unit,'token',la.alias,'token_unit',la.recon_unit,'cases',count(*))
  from bi.fact_case c join bi.location_alias la on la.source='branch_token' and la.recon_unit<>c.recon_unit
   and bi.norm(c.branch) ~ ('(^|[^A-Z])'||la.alias||'([^A-Z]|$)')
  where c.case_id in (select case_id from _n) group by c.branch,c.recon_unit,la.alias,la.recon_unit;
  return n;
end $$;

create or replace function bi.commit_point(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = bi, public as $$
declare b bi.import_batch; r jsonb;
begin
  select * into b from bi.import_batch where id=p_batch for update;
  create temp table _p on commit drop as
  select distinct on (point_id) * from (
    select s.seq, (p->>'point_id')::bigint point_id, (p->>'case_id')::bigint case_id, p->>'branch' branch, p->>'client_code' client_code_raw,
      p->>'point_type' point_type, bi.norm(p->>'created_by') created_by, (p->>'created_at')::timestamptz created_at, bi.norm(p->>'assign_to') assign_to,
      p->>'status' status, bi.norm(p->>'verified_by') verified_by, bi.norm(p->>'completed_by') completed_by,
      (p->>'assigned_at')::timestamptz assigned_at, (p->>'field_reviewed_at')::timestamptz field_reviewed_at, (p->>'completed_at')::timestamptz completed_at,
      case when p->>'pincode' ~ '^\d{6}$' then (p->>'pincode')::int end pincode, (p->>'has_address')::boolean has_address,
      hashtextextended(md5((p - '_src_row')::text),0) row_hash
    from bi.stg_row s, lateral (select s.payload p) x
    where s.batch_id=p_batch and (p->>'point_id') ~ '^\d+$' and (p->>'case_id') ~ '^\d+$') q
  order by point_id, seq desc;
  with ex as (select n.*, c.point_id ex_id, c.row_hash ex_hash, c.file_group ex_group, c.status ex_status from _p n left join bi.point_store c using (point_id)),
  cls as (select *, case when ex_id is null then 'new' when ex_hash=row_hash then 'unchanged' when ex_group=b.location_group then 'changed'
                         when bi.status_rank(status) >= bi.status_rank(ex_status) then 'cross_file_replace' else 'cross_file_keep' end k from ex),
  dq as (insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)
         select p_batch,'point',point_id::text,'point_in_multiple_location_files','info',jsonb_build_object('existing_group',ex_group,'new_group',b.location_group,'action',k)
         from cls where k like 'cross_file%' returning 1),
  up as (insert into bi.point_store as t(point_id,case_id,branch_id,client_code_raw,point_type_id,created_by_id,created_at,assign_to_id,status,verified_by_id,completed_by_id,
                                         assigned_at,field_reviewed_at,completed_at,pincode,has_address,file_group,recon_unit,row_hash,last_batch)
         select point_id,case_id,bi.dim_id('branch',branch),client_code_raw,bi.dim_id('point_type',point_type),bi.dim_id('emp',created_by),created_at,
                bi.dim_id('emp',assign_to),status,bi.dim_id('emp',verified_by),bi.dim_id('emp',completed_by),assigned_at,field_reviewed_at,completed_at,pincode,has_address,
                coalesce((select winner from bi.group_precedence g where (g.group_a,g.group_b) in ((ex_group,b.location_group),(b.location_group,ex_group))), b.location_group),
                null,row_hash,p_batch
         from cls where k in ('new','changed','cross_file_replace','unchanged')
         on conflict (point_id) do update set case_id=excluded.case_id, branch_id=excluded.branch_id, client_code_raw=excluded.client_code_raw,
           point_type_id=excluded.point_type_id, created_by_id=excluded.created_by_id, created_at=excluded.created_at, assign_to_id=excluded.assign_to_id,
           status=excluded.status, verified_by_id=excluded.verified_by_id, completed_by_id=excluded.completed_by_id, assigned_at=excluded.assigned_at,
           field_reviewed_at=excluded.field_reviewed_at, completed_at=excluded.completed_at, pincode=excluded.pincode, has_address=excluded.has_address,
           file_group=excluded.file_group, row_hash=excluded.row_hash, last_batch=excluded.last_batch
         returning 1)
  select jsonb_build_object('rows_in',(select count(*) from bi.stg_row where batch_id=p_batch),'distinct',(select count(*) from cls),
     'new',count(*) filter (where k='new'),'changed',count(*) filter (where k in ('changed','cross_file_replace')),
     'unchanged',count(*) filter (where k in ('unchanged','cross_file_keep')),'upserted',(select count(*) from up),'dq',(select count(*) from dq)) into r from cls;
  update bi.point_store p set recon_unit = la.recon_unit from bi.location_alias la where la.source='case_file' and la.alias=bi.norm(p.file_group) and p.point_id in (select point_id from _p);
  insert into bi.point_type(name,category,rule,review_status)
    select distinct point_type,'unknown','new point type seen in upload','needs_review' from _p where point_type is not null on conflict do nothing;
  update bi.import_batch set rows_in=rows_in+(r->>'rows_in')::int, rows_new=rows_new+(r->>'new')::int,
         rows_changed=rows_changed+(r->>'changed')::int, rows_unchanged=rows_unchanged+(r->>'unchanged')::int,
         rows_rejected=rows_rejected+(r->>'rows_in')::int-(r->>'distinct')::int where id=p_batch;
  delete from bi.stg_row where batch_id=p_batch;
  return r;
end $$;

-- Business rule (Shantanu, 12-Oct-2026): field executives submit ONLY field points; anyone who also creates cases/points
-- or handles any non-field point is back office, and their field submissions are manual.
create or replace function bi.refresh_employee_classification(p_min_points integer default 0) returns integer
language plpgsql security definer set search_path = bi, public as $$
declare n int;
begin
  with act as (
    select v.val name_key, count(*) total, count(*) filter (where t.category='field') field, count(*) filter (where t.category='document') doc,
           count(*) filter (where t.category='tele') tele, 0::bigint created
    from bi.point_store p join bi.dim v on v.id=p.verified_by_id left join bi.dim pt on pt.id=p.point_type_id left join bi.point_type t on t.name=pt.val group by 1
    union all
    select c.val, 0, 0, 0, 0, count(*) from bi.point_store p join bi.dim c on c.id=p.created_by_id group by 1),
  agg as (select name_key, sum(total) total, sum(field) field, sum(doc) doc, sum(tele) tele, sum(created) created from act group by 1)
  insert into bi.employee(name_key, display_name, classification, rule, evidence)
  select name_key, initcap(name_key),
         case when created > 0 or total - field > 0 then 'back_office' when field > 0 then 'field_executive' else 'unclassified' end,
         'Business rule 12-Oct-2026: creates cases/points or verifies any non-field point => back office (field submissions manual); only-field submitter => field executive (Force)',
         jsonb_build_object('field',field,'document',doc,'tele',tele,'other',total-field-doc-tele,'total',total,'created_points',created,'as_of',now())
  from agg
  on conflict (name_key) do update set classification = case when bi.employee.override then bi.employee.classification else excluded.classification end,
     rule = excluded.rule, evidence = excluded.evidence;
  get diagnostics n = row_count; return n;
end $$;

-- Business decisions (Shantanu, 12-Oct-2026)
update bi.point_type set category='document', review_status='confirmed', reviewed_by='business decision (Shantanu)', reviewed_at=now()
 where name='Udyam Registration Certificate';
update bi.location_alias set review_status='confirmed', reviewed_by='business decision (Shantanu)', reviewed_at=now(),
  evidence = coalesce(evidence,'{}') || '{"business_confirmation":"Grouping was Punjab + Rajasthan on 1-Oct; Rajasthan then moved to Delhi + Rajasthan (3-Oct)"}'
 where alias='PUNJAB+RAJISTHAN';
truncate bi.stg_row;
insert into bi.audit_log(actor,action,entity,detail) values ('migration','refactor','storage','{"migration":"bi_016","note":"compact stores + decoding views; employee rule; Udyam=document; Punjab alias confirmed"}');


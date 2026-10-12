-- Applied to Supabase project via MCP on 20261012102700

create table bi.dim (id serial primary key, kind text not null, val text not null, unique (kind, val));
alter table bi.dim enable row level security;
create or replace function bi.dim_id(p_kind text, p_val text) returns int
language plpgsql set search_path = bi, public as $$
declare i int;
begin
  if p_val is null then return null; end if;
  select id into i from bi.dim where kind = p_kind and val = p_val;
  if i is null then
    insert into bi.dim(kind, val) values (p_kind, p_val) on conflict do nothing returning id into i;
    if i is null then select id into i from bi.dim where kind = p_kind and val = p_val; end if;
  end if;
  return i;
end $$;

create table bi.case_store (
  case_id bigint primary key, client_code text, branch_id int, branch_code text, area_office_id int, status text,
  received_at timestamptz, completed_at timestamptz, due_at timestamptz, product_id int, points_declared smallint,
  file_group text not null, recon_unit text, location_id int,
  received_month date generated always as (date_trunc('month', (received_at at time zone 'Asia/Kolkata'))::date) stored,
  row_hash bigint not null, last_batch int);
create table bi.point_store (
  point_id bigint primary key, case_id bigint not null, branch_id int, client_code_raw text, point_type_id int,
  created_by_id int, created_at timestamptz, assign_to_id int, status text, verified_by_id int, completed_by_id int,
  assigned_at timestamptz, field_reviewed_at timestamptz, completed_at timestamptz, pincode int, has_address boolean,
  file_group text not null, recon_unit text,
  created_month date generated always as (date_trunc('month', (created_at at time zone 'Asia/Kolkata'))::date) stored,
  row_hash bigint not null, last_batch int);
alter table bi.case_store enable row level security; alter table bi.point_store enable row level security;

insert into bi.dim(kind,val)
  select 'branch', branch from bi.fact_case where branch is not null union
  select 'branch', branch from bi.fact_point where branch is not null union
  select 'area_office', area_office from bi.fact_case where area_office is not null union
  select 'product', product from bi.fact_case where product is not null union
  select 'point_type', point_type from bi.fact_point where point_type is not null union
  select 'emp', created_by from bi.fact_point where created_by is not null union
  select 'emp', assign_to from bi.fact_point where assign_to is not null union
  select 'emp', verified_by from bi.fact_point where verified_by is not null union
  select 'emp', completed_by from bi.fact_point where completed_by is not null
on conflict do nothing;

insert into bi.case_store(case_id,client_code,branch_id,branch_code,area_office_id,status,received_at,completed_at,due_at,product_id,points_declared,file_group,recon_unit,location_id,row_hash,last_batch)
select c.case_id, c.client_code, b.id, nullif(c.branch_code,''), ao.id, c.status, c.received_at, c.completed_at, c.due_at, pr.id, c.points_declared,
       c.file_group, c.recon_unit, c.location_id, hashtextextended(c.row_hash,0), c.last_batch
from bi.fact_case c
left join bi.dim b on b.kind='branch' and b.val=c.branch
left join bi.dim ao on ao.kind='area_office' and ao.val=c.area_office
left join bi.dim pr on pr.kind='product' and pr.val=c.product;


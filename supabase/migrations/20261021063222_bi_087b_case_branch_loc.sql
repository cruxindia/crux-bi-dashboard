-- Applied to Supabase project via MCP on 20261021063222
-- bi_087b: raw (client code, branch code) -> attributed tracker location, so the Force1 view joins on plain text keys (no per-row normalisation)
create table if not exists bi.case_branch_loc (
  client_code text not null, branch_code text not null, location_id int references bi.location(id), primary key (client_code, branch_code));
alter table bi.case_branch_loc enable row level security;

create or replace function bi.case_branch_attr_refresh() returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $$
declare n int; n2 int;
begin
  insert into bi.case_branch_attr as t (fam, code_norm, location_id, basis, refreshed_at)
  select x.fam, x.cn, m.location_id, case when m.location_id is not null then 'branch_master' when m.found then 'branch_outside_territory' else 'branch_not_in_master' end, now()
  from (select distinct cl.family fam, bi.norm_code(c.branch_code) cn from bi.case_store c join bi.client cl on cl.code = c.client_code
        where c.branch_code is not null) x
  left join lateral (select true found, b.location_id from bi.client_branch_master b
                     left join bi.location l on l.id = b.location_id
                     where b.client_family = x.fam and b.code_norm = x.cn
                     order by (b.location_id is not null and not coalesce(l.is_rollup, false)) desc, (b.status = 'active') desc, b.updated_at desc limit 1) m on true
  where x.cn is not null
  on conflict (fam, code_norm) do update set location_id = excluded.location_id, basis = excluded.basis, refreshed_at = now()
    where t.location_id is distinct from excluded.location_id or t.basis is distinct from excluded.basis;
  get diagnostics n = row_count;
  insert into bi.case_branch_loc as t (client_code, branch_code, location_id)
  select x.client_code, x.branch_code, a.location_id
  from (select distinct c.client_code, c.branch_code from bi.case_store c where c.branch_code is not null) x
  join bi.client cl on cl.code = x.client_code
  left join bi.case_branch_attr a on a.fam = cl.family and a.code_norm = bi.norm_code(x.branch_code)
  on conflict (client_code, branch_code) do update set location_id = excluded.location_id where t.location_id is distinct from excluded.location_id;
  get diagnostics n2 = row_count;
  insert into bi.refresh_state(name, source_version, refreshed_at, rows, ms)
  values ('case_branch_attr', (select coalesce(max(id), 0) from bi.audit_log), now(), n + n2, 0)
  on conflict (name) do update set source_version = excluded.source_version, refreshed_at = excluded.refreshed_at, rows = excluded.rows;
  return jsonb_build_object('changed', n + n2, 'branches', (select count(*) from bi.case_branch_attr), 'located', (select count(*) from bi.case_branch_attr where location_id is not null),
                            'raw_keys', (select count(*) from bi.case_branch_loc));
end $$;

select bi.case_branch_attr_refresh();

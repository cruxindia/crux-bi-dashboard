-- Applied to Supabase project via MCP on 20261021063129
-- bi_087a (21-Oct-2026): Force1 case branch -> Zonal Tracker location (AUDIT_REGISTER A2, part 1)
create table if not exists bi.case_branch_attr (
  fam text not null, code_norm text not null, location_id int references bi.location(id),
  basis text not null, refreshed_at timestamptz not null default now(), primary key (fam, code_norm));
alter table bi.case_branch_attr enable row level security;
comment on table bi.case_branch_attr is 'Force1 case branch (client family + normalised branch code) -> Zonal Tracker location via the client branch master; null location = branch not located';

create or replace function bi.case_branch_attr_refresh() returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $$
declare n int;
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
  insert into bi.refresh_state(name, source_version, refreshed_at, rows, ms)
  values ('case_branch_attr', (select coalesce(max(id), 0) from bi.audit_log), now(), n, 0)
  on conflict (name) do update set source_version = excluded.source_version, refreshed_at = excluded.refreshed_at, rows = excluded.rows;
  return jsonb_build_object('changed', n, 'branches', (select count(*) from bi.case_branch_attr), 'located', (select count(*) from bi.case_branch_attr where location_id is not null));
end $$;

select bi.case_branch_attr_refresh();

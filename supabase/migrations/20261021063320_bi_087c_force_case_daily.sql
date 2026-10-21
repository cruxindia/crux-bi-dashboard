-- Applied to Supabase project via MCP on 20261021063320
-- bi_087c (21-Oct-2026): compact daily Force1 case counts by processing team and by attributed (bank-branch) location group.
-- About 12k rows; refreshed after Case Wise imports or branch-master changes; read by bi.v_force_usage.
create table if not exists bi.force_case_daily (
  month date not null, proc_unit text not null, attr_unit text not null, by_branch boolean not null, client_family text not null,
  received_date date not null, n int not null,
  primary key (month, proc_unit, attr_unit, by_branch, client_family, received_date));
alter table bi.force_case_daily enable row level security;
comment on table bi.force_case_daily is 'Force1 cases per day: proc_unit = team whose Case Wise file contained the case; attr_unit = location group of the case''s bank branch (client branch master), or proc_unit when the branch is not located; ''~outside'' = branch located in a tracker location with no Force1 location group. n = 0 rows are combinations that no longer occur.';

create or replace function bi.force_case_daily_refresh() returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $$
declare t0 timestamptz := clock_timestamp(); n_up int; n_zero int;
begin
  perform bi.case_branch_attr_refresh();
  create temp table _fcd on commit drop as
  select s.received_month as month, s.recon_unit as proc_unit,
         case when a.location_id is null then s.recon_unit else coalesce(la.recon_unit, '~outside') end as attr_unit,
         (a.location_id is not null) as by_branch, cl.family as client_family,
         (s.received_at at time zone 'Asia/Kolkata')::date as received_date, count(*)::int as n
  from bi.case_store s join bi.client cl on cl.code = s.client_code
  left join bi.case_branch_loc a on a.client_code = s.client_code and a.branch_code = s.branch_code
  left join bi.location la on la.id = a.location_id and not la.is_rollup
  where s.recon_unit is not null and s.received_at >= '2024-03-31 18:30:00+00'
  group by 1, 2, 3, 4, 5, 6;
  insert into bi.force_case_daily as t (month, proc_unit, attr_unit, by_branch, client_family, received_date, n)
  select month, proc_unit, attr_unit, by_branch, client_family, received_date, n from _fcd
  on conflict (month, proc_unit, attr_unit, by_branch, client_family, received_date) do update set n = excluded.n where t.n <> excluded.n;
  get diagnostics n_up = row_count;
  update bi.force_case_daily t set n = 0
   where t.n <> 0 and not exists (select 1 from _fcd x where x.month = t.month and x.proc_unit = t.proc_unit and x.attr_unit = t.attr_unit
                                   and x.by_branch = t.by_branch and x.client_family = t.client_family and x.received_date = t.received_date);
  get diagnostics n_zero = row_count;
  insert into bi.refresh_state(name, source_version, refreshed_at, rows, ms)
  values ('force_case_daily', (select coalesce(max(last_batch), 0) from bi.case_store), now(), n_up + n_zero, extract(milliseconds from clock_timestamp() - t0)::int)
  on conflict (name) do update set source_version = excluded.source_version, refreshed_at = excluded.refreshed_at, rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('upserted', n_up, 'zeroed', n_zero, 'rows', (select count(*) from bi.force_case_daily), 'ms', extract(milliseconds from clock_timestamp() - t0)::int);
end $$;

create or replace function bi.force_case_daily_refresh_if_stale() returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $$
declare v_cases bigint := (select coalesce(max(last_batch), 0) from bi.case_store);
        v_master timestamptz := (select max(updated_at) from bi.client_branch_master);
begin
  if exists (select 1 from bi.refresh_state where name = 'force_case_daily' and source_version >= v_cases and refreshed_at >= coalesce(v_master, '-infinity')) then
    return jsonb_build_object('stale', false);
  end if;
  return bi.force_case_daily_refresh();
end $$;

select bi.force_case_daily_refresh();

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'bi-force-attr-refresh') then
    perform cron.schedule('bi-force-attr-refresh', '2-59/10 * * * *', $c$select bi.force_case_daily_refresh_if_stale()$c$);
  end if;
end $$;

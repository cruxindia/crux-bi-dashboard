-- Applied to Supabase project via MCP on 20261014163914
create table if not exists bi.branch_activity(
  fam text not null,
  code_norm text not null,
  last_m date, first_m date, n int, n3 int,
  refreshed_at timestamptz not null default now(),
  primary key (fam, code_norm));
alter table bi.branch_activity enable row level security;

create or replace function bi.branch_activity_refresh()
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare t0 timestamptz := clock_timestamp(); n int; v bigint := bi.point_source_version();
begin
  insert into bi.branch_activity(fam, code_norm, last_m, first_m, n, n3, refreshed_at)
  select coalesce(c.family, s.client_code), bi.norm_code(s.branch_code), max(s.received_month), min(s.received_month), count(*),
         count(*) filter (where s.received_month >= (date_trunc('month', current_date) - interval '3 months')::date and s.received_month < date_trunc('month', current_date)::date), now()
  from bi.case_store s left join bi.client c on c.code = s.client_code
  where bi.norm_code(s.branch_code) is not null group by 1, 2
  on conflict (fam, code_norm) do update set last_m = excluded.last_m, first_m = excluded.first_m, n = excluded.n, n3 = excluded.n3, refreshed_at = excluded.refreshed_at;
  get diagnostics n = row_count;
  insert into bi.refresh_state(name, refreshed_at, source_version, rows, ms) values ('branch_activity', now(), v, n, (extract(epoch from clock_timestamp() - t0) * 1000)::int)
  on conflict (name) do update set refreshed_at = excluded.refreshed_at, source_version = excluded.source_version, rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('rows', n, 'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int);
end $$;

create or replace function bi.branch_activity_refresh_if_stale()
returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if exists (select 1 from bi.refresh_state where name = 'branch_activity' and source_version >= bi.point_source_version()
             and refreshed_at >= date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata') then
    return jsonb_build_object('stale', false);
  end if;
  return bi.branch_activity_refresh();
end $$;

select bi.branch_activity_refresh();

do $$
declare d text; d2 text; a int; b int;
begin
  d := pg_get_functiondef('bi.api_branch_coverage(jsonb)'::regprocedure);
  a := position('seen as (' in d); b := position('cut as (' in d);
  if a = 0 or b = 0 then raise exception 'anchors'; end if;
  d2 := substr(d, 1, a - 1) || 'seen as (select fam, code_norm bk, last_m, first_m, n, n3 from bi.branch_activity),
' || substr(d, b);
  d2 := replace(d2, '''master_rows'', (select count(*) from bi.client_branch_master),', '''master_rows'', (select count(*) from m),');
  if position('bi.branch_activity' in d2) = 0 then raise exception 'patch failed'; end if;
  execute d2;
end $$;

alter function public.bi_call(text, jsonb) set statement_timeout = '45s';

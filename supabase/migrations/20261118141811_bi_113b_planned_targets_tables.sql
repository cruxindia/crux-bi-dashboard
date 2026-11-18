-- Applied to Supabase project via MCP on 20261118141811
-- wave 113b (18-Nov-2026, owner 19:30 IST): planned targets for a running month whose tracker files carry no targets (part 1: tables, sheet copy)
create table if not exists bi.target_fill_set (
  id bigserial primary key,
  month date not null,
  status text not null default 'active' check (status in ('active', 'replaced_by_owner', 'withdrawn')),
  method text, totals jsonb, bridge jsonb,
  created_by text, created_at timestamptz not null default now(), reason text,
  ended_at timestamptz, ended_by text, replaced_by_snapshot date);
create unique index if not exists target_fill_set_one_active on bi.target_fill_set (month) where status = 'active';
create table if not exists bi.target_fill_row (
  set_id bigint not null references bi.target_fill_set(id) on delete cascade,
  location_id integer not null, client_code text not null,
  target_cases numeric, revenue_target numeric, rate numeric, situation text, calc text, reason text,
  primary key (set_id, location_id, client_code));
create table if not exists bi.target_fill_log (
  id bigserial primary key,
  snapshot_date date not null, sheet_row integer not null, set_id bigint references bi.target_fill_set(id),
  kind text not null check (kind in ('planned', 'owner', 'withdrawn')),
  old_target_cases numeric, old_revenue_target numeric, old_achievement numeric, old_shortfall numeric,
  new_target_cases numeric, new_revenue_target numeric, source_snapshot date,
  current boolean not null default true, at timestamptz not null default now(), by text);
create index if not exists target_fill_log_cur on bi.target_fill_log (snapshot_date, sheet_row) where current;
alter table bi.target_fill_set enable row level security;
alter table bi.target_fill_row enable row level security;
alter table bi.target_fill_log enable row level security;
revoke all on bi.target_fill_set, bi.target_fill_row, bi.target_fill_log from public, anon, authenticated;

-- The target sheet for the running month, planned as at its start: a copy of bi.api_target_sheet whose base is the previous month (complete).
do $$ declare d text := pg_get_functiondef('bi.api_target_sheet(date,jsonb,jsonb)'::regprocedure); o text; n int; i int;
  reps text[] := array[
   'FUNCTION bi.api_target_sheet(', 'FUNCTION bi.target_sheet_running(',
   'into v_l, v_share, v_asof, v_inact from bi.potential_run x order by x.run_id desc limit 1;',
   'into v_l, v_share, v_asof, v_inact from bi.potential_run x order by x.run_id desc limit 1;
  -- wave 113b: planned targets for the running month (the latest tracker month), as at its start: the previous month is the complete base
  if v_m is distinct from v_l then return jsonb_build_object(''error'', format(''Planned targets are made only for the running tracker month (%s).'', to_char(v_l, ''Mon-YY''))); end if;
  v_l := (v_m - interval ''1 month'')::date; v_share := 1; v_asof := (v_m - 1);',
   'if v_m is null or v_m <= v_l or v_m > (v_l + interval ''12 months'')::date then', 'if v_m is null then'];
begin
  for i in 1..array_length(reps, 1) / 2 loop
    o := reps[2*i-1]; n := (length(d) - length(replace(d, o, ''))) / length(o);
    if n <> 1 then raise exception 'target_sheet_running: replacement % found % times', i, n; end if;
    d := replace(d, o, reps[2*i]);
  end loop;
  execute d;
end $$;
comment on function bi.target_sheet_running(date, jsonb, jsonb) is 'wave 113b: target sheet for the running tracker month with the previous month (complete) as the base; copy of bi.api_target_sheet as of 18-Nov-2026.';
revoke all on function bi.target_sheet_running(date, jsonb, jsonb) from public, anon, authenticated;

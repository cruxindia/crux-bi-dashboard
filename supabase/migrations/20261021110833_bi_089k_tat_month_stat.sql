-- Applied to Supabase project via MCP on 20261021110833
-- bi_089k (21-Oct-2026): stored TAT statistics for complete months (Pan India scope), so Ask Crux and trend questions answer in seconds
create table if not exists bi.tat_month_stat (
  month date not null, grp text not null, key text not null, stat jsonb not null, computed_at timestamptz not null default now(),
  primary key (month, grp, key));
alter table bi.tat_month_stat enable row level security;
comment on table bi.tat_month_stat is 'Pan India TAT statistics per complete month and grouping (unit / client / location / total) — cache of bi.ask_tat_stats; rebuilt by bi.tat_month_stat_refresh_if_stale()';

create or replace function bi.tat_month_stat_refresh(p_months int default 13) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '280s' as $function$
declare om date := (select max(received_month) from bi.case_store); mm date[]; g text; n int := 0; t0 timestamptz := clock_timestamp(); x jsonb;
begin
  select array_agg(d::date order by d) into mm from generate_series((om - make_interval(months => p_months))::date, (om - interval '1 month')::date, interval '1 month') d;
  foreach g in array array['unit', 'client', 'location'] loop
    for x in select value from jsonb_array_elements(bi.ask_tat_stats_live(mm, '{}'::jsonb, g)) loop
      insert into bi.tat_month_stat as t (month, grp, key, stat, computed_at)
      values ((x->>'month')::date, case when x->>'key' = '~total' then 'total' else g end, coalesce(x->>'key', '(none)'), x, now())
      on conflict (month, grp, key) do update set stat = excluded.stat, computed_at = now() where t.stat is distinct from excluded.stat;
      n := n + 1;
    end loop;
  end loop;
  insert into bi.refresh_state(name, source_version, refreshed_at, rows, ms)
  values ('tat_month_stat', bi.point_source_version(), now(), n, extract(milliseconds from clock_timestamp() - t0)::int)
  on conflict (name) do update set source_version = excluded.source_version, refreshed_at = excluded.refreshed_at, rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('rows', n, 'months', array_length(mm, 1), 'ms', extract(milliseconds from clock_timestamp() - t0)::int);
end $function$;

do $do$
declare d text := pg_get_functiondef('bi.ask_tat_stats(date[],jsonb,text)'::regprocedure);
begin
  if to_regprocedure('bi.ask_tat_stats_live(date[],jsonb,text)') is not null then return; end if;
  execute replace(d, 'CREATE OR REPLACE FUNCTION bi.ask_tat_stats(', 'CREATE OR REPLACE FUNCTION bi.ask_tat_stats_live(');
end $do$;

create or replace function bi.tat_month_stat_refresh_if_stale() returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' as $function$
begin
  if exists (select 1 from bi.refresh_state where name = 'tat_month_stat' and source_version >= bi.point_source_version()
             and refreshed_at >= (select max(updated_at) from bi.tat_rule)
             and refreshed_at >= coalesce((select max(committed_at) from bi.import_batch where source_category = 'case' and status = 'committed'), '-infinity')) then
    return jsonb_build_object('stale', false);
  end if;
  return bi.tat_month_stat_refresh();
end $function$;

create or replace function bi.ask_tat_stats(p_months date[], f jsonb, grp text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare om date := (select max(received_month) from bi.case_store); stored date[]; live date[]; r jsonb := '[]';
begin
  if coalesce(f, '{}'::jsonb) = '{}'::jsonb and grp in ('unit', 'client', 'location') then
    select array_agg(m) into stored from unnest(p_months) m
     where m < om and exists (select 1 from bi.tat_month_stat t where t.month = m and t.grp = 'total');
  end if;
  select array_agg(m) into live from unnest(p_months) m where stored is null or not (m = any(stored));
  if stored is not null then
    select coalesce(jsonb_agg(t.stat), '[]') into r from bi.tat_month_stat t where t.month = any(stored) and t.grp in (grp, 'total');
  end if;
  if live is not null then r := r || bi.ask_tat_stats_live(live, f, grp); end if;
  return r;
end $function$;

do $do$ begin
  if not exists (select 1 from cron.job where jobname = 'bi-tat-month-stat') then
    perform cron.schedule('bi-tat-month-stat', '8-59/10 * * * *', $c$set statement_timeout = '290s'; select bi.tat_month_stat_refresh_if_stale()$c$);
  end if;
end $do$;

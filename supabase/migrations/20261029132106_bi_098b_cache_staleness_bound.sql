-- Applied to Supabase project via MCP on 20261029132106
-- Wave 098: bound how old a figure the stale-while-revalidate path (D191) may serve.
-- Found 29-Oct: 1,449 of 1,739 cached figures were more than 24 h old (oldest 12-Oct) and could be served as-is all day, and figures computed
-- before the 29-Oct month-history / organic corrections (D187–D189) were still served on Growth → organic by branch manager (Sep-26 58,454 vs corrected 58,065).
-- Rule now: an older-version figure is served (and refreshed in the background) only when it was computed in the last 24 h AND after the latest
-- correction floor in bi.api_cache_floor; otherwise it is computed on the spot, as before D191.
create table if not exists bi.api_cache_floor (
  id bigint generated always as identity primary key,
  floor_at timestamptz not null,
  reason text not null,
  set_by text not null,
  set_at timestamptz not null default now()
);
alter table bi.api_cache_floor enable row level security;
comment on table bi.api_cache_floor is 'Wave 098: cached figures computed before the latest floor_at are never served stale (a data correction makes them unsafe to show).';

insert into bi.api_cache_floor(floor_at, reason, set_by)
select timestamptz '2026-10-29 06:24:00+00', 'D187–D189: month-history supersede (audit 5046) and organic retire-pairs refresh (06:23 UTC) changed Aug/Sep-26 totals', 'wave098 migration'
where not exists (select 1 from bi.api_cache_floor);

do $mig$
declare d text := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
        a1 text := 'r jsonb; c_ver bigint;';
        b1 text := 'r jsonb; c_ver bigint; c_at timestamptz;';
        a2 text := 'select v, version into r, c_ver from bi.api_cache where k = v_key;';
        b2 text := 'select v, version, computed_at into r, c_ver, c_at from bi.api_cache where k = v_key;
  -- wave 098: an older-version figure is served only when it is recent (24 h) and computed after the latest correction floor; otherwise compute now
  if r is not null and c_ver is distinct from v_ver
     and (c_at < now() - interval ''24 hours'' or c_at < (select coalesce(max(floor_at), ''-infinity''::timestamptz) from bi.api_cache_floor)) then
    r := null;
  end if;';
begin
  if (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1 then raise exception 'bi_call fragment 1 not found exactly once'; end if;
  if (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 then raise exception 'bi_call fragment 2 not found exactly once'; end if;
  d := replace(replace(d, a1, b1), a2, b2);
  execute d;
end $mig$;

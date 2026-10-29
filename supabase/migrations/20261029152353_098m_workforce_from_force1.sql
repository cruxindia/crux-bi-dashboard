-- Applied to Supabase project via MCP on 20261029152353
-- Owner rule 29-Oct-2026 (5.8.5): workforce and attrition come only from the Force1 reports.
-- A person who appears in Force1 is on the roll. No activity on the latest report day = absent; more than 15 days without
-- any activity = left (exit date = last day seen). If the person appears again, they are back on the roll and the whole gap
-- is counted as absent days, not as attrition. Activity = the person created, verified or completed a Force1 point that day.
create table if not exists bi.person_month (
  emp_id      integer  not null,          -- bi.dim id (kind 'emp')
  month       date     not null,
  active_days smallint not null,          -- days with any Force1 activity
  active_wd   smallint not null,          -- of those, working days (Mon–Sat, minus admin-marked non-working days)
  actions     integer  not null,
  first_d     date     not null,
  last_d      date     not null,
  max_gap     smallint not null default 0, -- longest run of days without activity that ended in this month
  gap_from    date,                       -- last active day before that run
  gap_to      date,                       -- first active day after it
  location_id integer,                    -- most frequent location of the person's verified points (month the case was created)
  recon_unit  text,                       -- most frequent location group of all the person's activity
  run         bigint   not null,          -- build run; the API reads only rows of the latest run
  primary key (emp_id, month)
);
alter table bi.person_month enable row level security;
comment on table bi.person_month is 'Force1 activity per person per month (wave 098, owner rule 5.8.5). Rebuilt by bi.person_activity_refresh(); rows of older runs are ignored.';

create table if not exists bi.person_activity_state (
  id smallint primary key default 1 check (id = 1),
  run bigint, as_of date, data_start date, people int, person_months int, out_of_range_events int,
  refreshed_at timestamptz, ms int
);
alter table bi.person_activity_state enable row level security;

create or replace function bi.person_activity_refresh() returns jsonb
language plpgsql security definer set search_path = bi, public set statement_timeout = '170s' as $fn$
declare t0 timestamptz := clock_timestamp(); v_src bigint := bi.point_source_version();
        v_today date := (now() at time zone 'Asia/Kolkata')::date;
        v_start date; v_asof date; v_n int; v_people int; v_oor int; v_ms int;
begin
  select min((created_at at time zone 'Asia/Kolkata')::date), max((created_at at time zone 'Asia/Kolkata')::date)
    into v_start, v_asof
    from bi.point_store where created_at is not null and (created_at at time zone 'Asia/Kolkata')::date <= v_today;
  if v_asof is null then return jsonb_build_object('built', false, 'reason', 'no Force1 point data'); end if;
  with ev as (
         select created_by_id emp, (created_at at time zone 'Asia/Kolkata')::date d, recon_unit ru from bi.point_store where created_by_id is not null and created_at is not null
         union all select verified_by_id, (field_reviewed_at at time zone 'Asia/Kolkata')::date, recon_unit from bi.point_store where verified_by_id is not null and field_reviewed_at is not null
         union all select completed_by_id, (completed_at at time zone 'Asia/Kolkata')::date, recon_unit from bi.point_store where completed_by_id is not null and completed_at is not null),
       dd as materialized (select emp, d, count(*)::int n, mode() within group (order by ru) ru from ev group by emp, d),
       ok as materialized (select dd.emp, dd.d, dd.n, dd.ru, lag(dd.d) over w prev_d, dd.d - lag(dd.d) over w - 1 idle
                             from dd where dd.d between v_start and v_asof window w as (partition by dd.emp order by dd.d)),
       pm as (select ok.emp, date_trunc('month', ok.d)::date mth, count(*)::smallint active_days,
                     count(*) filter (where extract(isodow from ok.d) <> 7 and not exists (select 1 from bi.report_calendar_exception e
                                       where e.report_date = ok.d and e.active and not e.working_day))::smallint active_wd,
                     sum(ok.n)::int actions, min(ok.d) first_d, max(ok.d) last_d, coalesce(max(ok.idle), 0)::smallint max_gap,
                     (array_agg(ok.prev_d order by ok.idle desc nulls last, ok.d))[1] gap_from,
                     (array_agg(ok.d order by ok.idle desc nulls last, ok.d))[1] gap_to,
                     mode() within group (order by ok.ru) ru
                from ok group by ok.emp, date_trunc('month', ok.d)),
       loc as (select pd.verifier_id emp, pd.created_month mth, mode() within group (order by pd.location_id) location_id
                 from bi.point_derived pd where pd.verifier_id is not null and pd.location_id is not null group by 1, 2),
       ins as (insert into bi.person_month as t (emp_id, month, active_days, active_wd, actions, first_d, last_d, max_gap, gap_from, gap_to, location_id, recon_unit, run)
               select pm.emp, pm.mth, pm.active_days, pm.active_wd, pm.actions, pm.first_d, pm.last_d, pm.max_gap,
                      case when pm.max_gap > 0 then pm.gap_from end, case when pm.max_gap > 0 then pm.gap_to end, loc.location_id, pm.ru, v_src
                 from pm left join loc on loc.emp = pm.emp and loc.mth = pm.mth
               on conflict (emp_id, month) do update set active_days = excluded.active_days, active_wd = excluded.active_wd, actions = excluded.actions,
                  first_d = excluded.first_d, last_d = excluded.last_d, max_gap = excluded.max_gap, gap_from = excluded.gap_from, gap_to = excluded.gap_to,
                  location_id = excluded.location_id, recon_unit = excluded.recon_unit, run = excluded.run
               returning t.emp_id)
  select (select count(*) from ins), (select count(distinct emp_id) from ins), (select coalesce(sum(n), 0) from dd where d not between v_start and v_asof)
    into v_n, v_people, v_oor;
  v_ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int;
  insert into bi.person_activity_state as s (id, run, as_of, data_start, people, person_months, out_of_range_events, refreshed_at, ms)
  values (1, v_src, v_asof, v_start, v_people, v_n, v_oor, now(), v_ms)
  on conflict (id) do update set run = excluded.run, as_of = excluded.as_of, data_start = excluded.data_start, people = excluded.people,
     person_months = excluded.person_months, out_of_range_events = excluded.out_of_range_events, refreshed_at = excluded.refreshed_at, ms = excluded.ms;
  insert into bi.refresh_state as r (name, refreshed_at, source_version, rows, ms) values ('person_month', now(), v_src, v_n, v_ms)
  on conflict (name) do update set refreshed_at = excluded.refreshed_at, source_version = excluded.source_version, rows = excluded.rows, ms = excluded.ms;
  return jsonb_build_object('built', true, 'as_of', v_asof, 'data_start', v_start, 'people', v_people, 'person_months', v_n, 'out_of_range_events', v_oor, 'ms', v_ms);
end $fn$;

create or replace function bi.person_activity_refresh_if_stale() returns jsonb
language plpgsql security definer set search_path = bi, public as $fn$
begin
  if exists (select 1 from bi.refresh_state r join bi.person_activity_state s on s.id = 1
              where r.name = 'person_month' and r.source_version >= bi.point_source_version()
                and s.refreshed_at >= coalesce((select max(greatest(e.set_at, coalesce(e.withdrawn_at, e.set_at))) from bi.report_calendar_exception e), '-infinity'::timestamptz)) then
    return jsonb_build_object('stale', false);
  end if;
  return bi.person_activity_refresh();
end $fn$;

create or replace function bi.api_workforce(p_month date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path = bi, public as $fn$
declare st bi.person_activity_state%rowtype; v_m date; v_me date; v_lim constant int := 15; res jsonb;
begin
  select * into st from bi.person_activity_state where id = 1;
  if not found or st.as_of is null then
    return jsonb_build_object('basis', 'force1', 'ready', false, 'note', 'Workforce activity is not built yet. It is built from the Force1 point reports by the night refresh.');
  end if;
  v_m := date_trunc('month', coalesce(p_month, st.as_of))::date;
  if v_m > date_trunc('month', st.as_of) then v_m := date_trunc('month', st.as_of)::date; end if;
  if v_m < date_trunc('month', st.data_start) then v_m := date_trunc('month', st.data_start)::date; end if;
  v_me := least((v_m + interval '1 month - 1 day')::date, st.as_of);
  f := coalesce(f, '{}'::jsonb);
  with cal as materialized (
         select g::date d, case when extract(isodow from g) <> 7 and not exists (select 1 from bi.report_calendar_exception e
                                 where e.report_date = g::date and e.active and not e.working_day) then 1 else 0 end wd
           from generate_series(st.data_start - 1, st.as_of, interval '1 day') g),
       cum as materialized (select cal.d, (sum(cal.wd) over (order by cal.d))::int c from cal),
       pm as materialized (select * from bi.person_month x where x.run = st.run and x.active_days > 0),
       p as materialized (select pm.emp_id, min(pm.first_d) first_d, max(pm.last_d) last_d, sum(pm.active_days)::int active_days from pm group by pm.emp_id),
       pl as materialized (select distinct on (pm.emp_id) pm.emp_id, pm.location_id, pm.recon_unit from pm order by pm.emp_id, pm.month desc),
       pp as materialized (
         select p.emp_id, p.first_d, p.last_d, p.active_days,
                coalesce(e.display_name, initcap(dm.val)) nm, coalesce(e.classification, 'unclassified') cls,
                pl.location_id, coalesce(l.label, pl.recon_unit, '(no location)') loc,
                st.as_of - p.last_d idle,
                p.first_d > st.data_start + v_lim joined_in_data,
                case when p.first_d > st.data_start + v_lim then p.first_d else st.data_start end ej,
                case when st.as_of - p.last_d > v_lim then p.last_d end exit_d
           from p join bi.dim dm on dm.id = p.emp_id
           left join bi.employee e on e.name_key = dm.val
           left join pl on pl.emp_id = p.emp_id
           left join bi.location l on l.id = pl.location_id
          where bi.loc_ok(pl.location_id, pl.recon_unit, f - 'client_family', v_m)),
       mo as materialized (select generate_series(date_trunc('month', st.data_start), date_trunc('month', st.as_of), interval '1 month')::date mm),
       mx as materialized (
         select mo.mm, least((mo.mm + interval '1 month - 1 day')::date, st.as_of) mme, pp.*,
                coalesce(x.active_wd, 0) awd, coalesce(x.active_days, 0) ad, coalesce(x.actions, 0) acts, x.max_gap, x.gap_from, x.gap_to
           from mo cross join pp left join pm x on x.emp_id = pp.emp_id and x.month = mo.mm),
       my as materialized (
         select mx.*,
                (mx.ej < mx.mm or (not mx.joined_in_data and mx.ej <= mx.mm)) and (mx.exit_d is null or mx.exit_d >= mx.mm) is_open,
                mx.joined_in_data and mx.first_d between mx.mm and mx.mme is_join,
                coalesce(mx.exit_d between mx.mm and mx.mme, false) is_left,
                mx.ej <= mx.mme and (mx.exit_d is null or mx.exit_d > mx.mme) is_close,
                greatest(mx.ej, mx.mm) r_lo, least(mx.mme, coalesce(mx.exit_d, st.as_of)) r_hi
           from mx),
       mw as materialized (
         select my.*, case when my.r_hi >= my.r_lo then ch.c - cl.c else 0 end wdr
           from my left join cum ch on ch.d = my.r_hi left join cum cl on cl.d = my.r_lo - 1),
       agg as (select mw.mm, count(*) filter (where is_open) opening, count(*) filter (where is_join) joined, count(*) filter (where is_left) lft,
                      count(*) filter (where is_close) closing, sum(wdr)::int wdr, sum(least(awd, wdr))::int awd
                 from mw group by mw.mm),
       grp as (select 'classification' g, mw.cls k, count(*) filter (where is_open) opening, count(*) filter (where is_join) joined, count(*) filter (where is_left) lft,
                      count(*) filter (where is_close) closing, sum(wdr)::int wdr, sum(least(awd, wdr))::int awd from mw where mw.mm = v_m group by mw.cls
               union all
               select 'location', mw.loc, count(*) filter (where is_open), count(*) filter (where is_join), count(*) filter (where is_left),
                      count(*) filter (where is_close), sum(wdr)::int, sum(least(awd, wdr))::int from mw where mw.mm = v_m group by mw.loc)
  select jsonb_build_object(
    'basis', 'force1', 'ready', true, 'month', v_m, 'as_of', st.as_of, 'data_start', st.data_start, 'refreshed_at', st.refreshed_at,
    'filters', f, 'left_after_days', v_lim,
    'headcount', (select jsonb_build_object('opening', opening, 'joined', joined, 'left', lft, 'closing', closing,
                     'attrition_rate', round(lft::numeric / nullif((opening + closing) / 2.0, 0), 4),
                     'on_roll_workdays', wdr, 'active_workdays', awd, 'absent_workdays', greatest(wdr - awd, 0),
                     'attendance_rate', round(awd::numeric / nullif(wdr, 0), 4)) from agg where mm = v_m),
    'today', (select jsonb_build_object('as_of', st.as_of, 'on_roll', count(*) filter (where exit_d is null),
                     'active', count(*) filter (where idle = 0), 'absent', count(*) filter (where idle between 1 and v_lim),
                     'left_total', count(*) filter (where exit_d is not null),
                     'worked_last_7_days', count(*) filter (where idle <= 6)) from pp),
    'trend', (select jsonb_agg(jsonb_build_object('month', mm, 'opening', opening, 'joined', joined, 'left', lft, 'closing', closing,
                     'attrition_rate', round(lft::numeric / nullif((opening + closing) / 2.0, 0), 4),
                     'attendance_rate', round(awd::numeric / nullif(wdr, 0), 4), 'partial', mm = date_trunc('month', st.as_of)) order by mm) from agg),
    'by_classification', (select coalesce(jsonb_agg(jsonb_build_object('group', replace(k, '_', ' '), 'opening', opening, 'joined', joined, 'left', lft, 'closing', closing,
                     'attrition_rate', round(lft::numeric / nullif((opening + closing) / 2.0, 0), 4), 'attendance_rate', round(awd::numeric / nullif(wdr, 0), 4))
                     order by closing desc), '[]'::jsonb) from grp where g = 'classification'),
    'by_location', (select coalesce(jsonb_agg(jsonb_build_object('group', k, 'opening', opening, 'joined', joined, 'left', lft, 'closing', closing,
                     'attrition_rate', round(lft::numeric / nullif((opening + closing) / 2.0, 0), 4), 'attendance_rate', round(awd::numeric / nullif(wdr, 0), 4))
                     order by lft desc, closing desc), '[]'::jsonb) from grp where g = 'location'),
    'absent_now', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'classification', cls, 'location', loc, 'last_seen', last_d, 'days_since', idle,
                     'absent_workdays', (select c from cum where d = st.as_of) - (select c from cum where d = pp.last_d),
                     'marked_left_after', pp.last_d + v_lim + 1) order by idle desc, nm), '[]'::jsonb)
                   from pp where idle between 1 and v_lim),
    'leavers', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'classification', cls, 'location', loc, 'first_seen', first_d, 'last_seen', exit_d,
                     'joined_in_data', joined_in_data,
                     'actions_3m_before', (select coalesce(sum(z.actions), 0) from pm z where z.emp_id = mw.emp_id
                                             and z.month >= (date_trunc('month', mw.exit_d) - interval '3 months')::date and z.month < date_trunc('month', mw.exit_d)::date),
                     'active_days_exit_month', ad) order by exit_d, nm), '[]'::jsonb)
                from mw where mm = v_m and is_left),
    'joiners', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'classification', cls, 'location', loc, 'first_seen', first_d) order by first_d, nm), '[]'::jsonb)
                from mw where mm = v_m and is_join),
    'returned', (select coalesce(jsonb_agg(jsonb_build_object('name', nm, 'classification', cls, 'location', loc, 'gap_from', gap_from, 'back_on', gap_to,
                     'days_without_activity', max_gap,
                     'absent_workdays', (select c from cum where d = mw.gap_to - 1) - (select c from cum where d = mw.gap_from)) order by gap_to, nm), '[]'::jsonb)
                 from mw where mm = v_m and max_gap > v_lim),
    'data', jsonb_build_object('people_seen', (select count(*) from pp), 'out_of_range_events', st.out_of_range_events, 'refreshed_at', st.refreshed_at),
    'definitions', jsonb_build_object(
       'source', 'Force1 point reports only (owner rule 29-Oct-2026). A person is anyone who created, verified or completed a Force1 point; a day counts as worked when the person did at least one of these that day.',
       'status', 'Active = worked on the latest report day (' || to_char(st.as_of, 'DD-Mon-YYYY') || '). Absent = not seen for 1 to ' || v_lim || ' days. Left = not seen for more than ' || v_lim || ' days; the exit date is the last day seen. If a person appears again, they are back on the roll and the gap counts as absent days, not as attrition.',
       'headcount', 'Opening = on the roll at the start of the month; joined = first seen in the month (people already seen in the first ' || v_lim || ' days of the Force1 data, ' || to_char(st.data_start, 'DD-Mon-YYYY') || ', count as existing staff); left = exit date in the month; closing = on the roll at the month end (or the latest report day).',
       'attrition_rate', 'Leavers in the month ÷ average of opening and closing headcount.',
       'attendance_rate', 'Days worked ÷ working days on the roll (Mon–Sat, minus days an admin marked as non-working), from the start date (or month start) to the exit date (or month end / latest report day).',
       'limits', 'Force1 shows activity, not employment: leave, training, a role that does not use Force1, or a changed login name all look like absence; the same person under two spellings counts twice. Location = where most of the person''s verified points were; a client filter does not apply to people.'))
  into res;
  return res;
end $fn$;

-- route the new endpoint (fragment patch, exactly once)
do $do$
declare src text; n int;
begin
  select pg_get_functiondef('bi.call_compute(text, jsonb)'::regprocedure) into src;
  n := (length(src) - length(replace(src, 'when ''attrition'' then bi.api_attrition(m, f)', ''))) / length('when ''attrition'' then bi.api_attrition(m, f)');
  if n <> 1 then raise exception 'call_compute fragment found % times', n; end if;
  if position('when ''workforce''' in src) = 0 then
    execute replace(src, 'when ''attrition'' then bi.api_attrition(m, f)', 'when ''attrition'' then bi.api_attrition(m, f) when ''workforce'' then bi.api_workforce(m, f)');
  end if;
  select pg_get_functiondef('public.bi_call(text, jsonb)'::regprocedure) into src;
  n := (length(src) - length(replace(src, '  if p_fn = ''meta'' then r := r ||', ''))) / length('  if p_fn = ''meta'' then r := r ||');
  if n <> 1 then raise exception 'bi_call fragment found % times', n; end if;
  if position('p_fn = ''workforce''' in src) = 0 then
    execute replace(src, '  if p_fn = ''meta'' then r := r ||',
'  -- workforce names (Force1-based HR view): admins only
  if p_fn = ''workforce'' and not v_admin and r ? ''absent_now'' then
    r := r || jsonb_build_object(''names_hidden'', true,
      ''absent_now'', (select coalesce(jsonb_agg(x - ''name'' || jsonb_build_object(''name'', ''(admin only)'') order by o), ''[]''::jsonb) from jsonb_array_elements(r->''absent_now'') with ordinality t(x, o)),
      ''leavers'',    (select coalesce(jsonb_agg(x - ''name'' || jsonb_build_object(''name'', ''(admin only)'') order by o), ''[]''::jsonb) from jsonb_array_elements(r->''leavers'') with ordinality t(x, o)),
      ''joiners'',    (select coalesce(jsonb_agg(x - ''name'' || jsonb_build_object(''name'', ''(admin only)'') order by o), ''[]''::jsonb) from jsonb_array_elements(r->''joiners'') with ordinality t(x, o)),
      ''returned'',   (select coalesce(jsonb_agg(x - ''name'' || jsonb_build_object(''name'', ''(admin only)'') order by o), ''[]''::jsonb) from jsonb_array_elements(r->''returned'') with ordinality t(x, o)));
  end if;
  if p_fn = ''meta'' then r := r ||');
  end if;
end $do$;

select cron.schedule('bi-person-activity', '50 19,22 * * *', $c$set statement_timeout = '180s'; select bi.person_activity_refresh_if_stale();$c$);

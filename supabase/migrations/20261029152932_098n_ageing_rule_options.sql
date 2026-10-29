-- Applied to Supabase project via MCP on 20261029152932
-- Owner 29-Oct-2026 (5.8.3): "You create them and suggest, I will select" — three ageing rules for open Force1 cases.
-- calendar (current default) · working (Mon–Sat minus admin-marked non-working days) · sla (time past the case's own due time).
-- The admin choice is stored in bi.app_setting and audited; every rule is also returned side by side for comparison.
create table if not exists bi.app_setting (
  key text primary key, value jsonb not null, note text, updated_by text, updated_at timestamptz not null default now());
alter table bi.app_setting enable row level security;
insert into bi.app_setting(key, value, note, updated_by)
values ('ops_ageing_rule', '"calendar"', 'Ageing rule for open Force1 cases: calendar | working | sla. Default kept until the owner selects (29-Oct-2026).', 'migration 098n')
on conflict (key) do nothing;

create or replace function bi.setting_admin(p_actor text, p jsonb) returns jsonb
language plpgsql security definer set search_path = bi, public as $fn$
declare v_key text := p->>'key'; v_val text := p->>'value'; v_old jsonb;
begin
  if coalesce(p->>'op', 'get') = 'get' then
    return jsonb_build_object('settings', (select coalesce(jsonb_object_agg(key, jsonb_build_object('value', value, 'updated_by', updated_by, 'updated_at', updated_at, 'note', note)), '{}'::jsonb) from bi.app_setting),
      'options', jsonb_build_object('ops_ageing_rule', jsonb_build_array(
        jsonb_build_object('value', 'calendar', 'label', 'Calendar days', 'text', 'Days since the case was received, counting Sundays and holidays. Simple, but a case received on Saturday looks two days old on Monday morning.'),
        jsonb_build_object('value', 'working', 'label', 'Working days', 'text', 'Days since the case was received, counting only Mon–Sat and skipping days an admin marked as non-working (Admin → Upload → Report calendar). Same buckets as today; fairer after Sundays and holidays.'),
        jsonb_build_object('value', 'sla', 'label', 'SLA (due time) — recommended', 'text', 'Time past the case''s own due time from Force1 (every open case carries one; SLAs differ by client and product: mostly 24, 48 or 72 hours). Shows whether a case is late and by how much, instead of how old it is.'))),
      'recommendation', 'sla');
  end if;
  if p->>'op' <> 'set' then raise exception 'unknown op %', p->>'op'; end if;
  if v_key is distinct from 'ops_ageing_rule' then raise exception 'unknown setting %', v_key; end if;
  if v_val is null or v_val not in ('calendar', 'working', 'sla') then raise exception 'value must be calendar, working or sla'; end if;
  if length(coalesce(trim(p->>'reason'), '')) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
  select value into v_old from bi.app_setting where key = v_key;
  insert into bi.app_setting as s(key, value, note, updated_by, updated_at) values (v_key, to_jsonb(v_val), p->>'reason', p_actor, now())
  on conflict (key) do update set value = excluded.value, note = excluded.note, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (p_actor, 'setting_change', 'app_setting', v_key, jsonb_build_object('from', v_old, 'to', v_val, 'reason', p->>'reason'));
  return jsonb_build_object('ok', true, 'key', v_key, 'from', v_old, 'to', v_val);
end $fn$;

do $do$
declare src text; n int; frag text;
begin
  -- 1) admin route
  select pg_get_functiondef('public.bi_admin(text, jsonb)'::regprocedure) into src;
  frag := $q$    when 'groups' then return bi.api_groups();$q$;
  n := (length(src) - length(replace(src, frag, ''))) / length(frag);
  if n <> 1 then raise exception 'bi_admin fragment found % times', n; end if;
  if position($q$when 'setting' then$q$ in src) = 0 then
    execute replace(src, frag, $q$    when 'setting' then return bi.setting_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
$q$ || frag);
  end if;

  -- 2) api_ops: rule-aware ageing + side-by-side comparison
  select pg_get_functiondef('bi.api_ops(date, jsonb)'::regprocedure) into src;
  if position('ageing_compare' in src) = 0 then
    frag := $q$declare m0 date; m1 date; v_asof date; r jsonb;$q$;
    n := (length(src) - length(replace(src, frag, ''))) / length(frag); if n <> 1 then raise exception 'api_ops declare found % times', n; end if;
    src := replace(src, frag, $q$declare m0 date; m1 date; v_asof date; r jsonb;
        v_rule text := coalesce((select value #>> '{}' from bi.app_setting where key = 'ops_ageing_rule'), 'calendar'); v_unit text; v_unit1 text;$q$);

    frag := $q$  v_asof := (select (max(received_at) at time zone 'Asia/Kolkata')::date from bi.case_store);$q$;
    n := (length(src) - length(replace(src, frag, ''))) / length(frag); if n <> 1 then raise exception 'api_ops asof found % times', n; end if;
    src := replace(src, frag, $q$  v_unit := case v_rule when 'working' then 'working days' else 'days' end; v_unit1 := case v_rule when 'working' then 'working day' else 'day' end;
$q$ || frag);

    n := (select count(*) from regexp_matches(src, 'ag as \(select case when a <= 1 then .*?and \(cd is null or cd > m1\)\) z\),', 'g'));
    if n <> 1 then raise exception 'api_ops ag CTE found % times', n; end if;
    src := regexp_replace(src, 'ag as \(select case when a <= 1 then .*?and \(cd is null or cd > m1\)\) z\),', $q$ag0 as materialized (select extract(epoch from ((m1 + 1)::timestamp at time zone 'Asia/Kolkata') - recv) / 86400.0 a,
                      extract(epoch from ((m1 + 1)::timestamp at time zone 'Asia/Kolkata') - due) / 86400.0 od, rd, loc, client, due
                 from ops where rd <= m1 and (cd is null or cd > m1)),
       nwcal as materialized (select g::date d, case when extract(isodow from g) = 7 or exists (select 1 from bi.report_calendar_exception e
                                       where e.report_date = g::date and e.active and not e.working_day) then 1 else 0 end nw
                                from generate_series(coalesce((select min(rd) from ag0), m1), m1, interval '1 day') g),
       nwc as materialized (select nwcal.d, (sum(nwcal.nw) over (order by nwcal.d))::int c from nwcal),
       ag1 as materialized (select ag0.*, greatest(ag0.a - ((select c from nwc where nwc.d = m1) - coalesce((select c from nwc where nwc.d = ag0.rd), 0)), 0) aw from ag0),
       ag as (select case when v_rule = 'sla' then case when z.due is null then 'No due time' when z.od <= 0 then 'Not yet due' when z.od <= 1 then 'Overdue ≤1 day' when z.od <= 3 then 'Overdue >1–3 days'
                                                         when z.od <= 7 then 'Overdue >3–7 days' when z.od <= 15 then 'Overdue >7–15 days' else 'Overdue >15 days' end
                          else case when z.x <= 1 then '0–1 ' || v_unit1 when z.x <= 3 then '>1–3 ' || v_unit when z.x <= 7 then '>3–7 ' || v_unit when z.x <= 15 then '>7–15 ' || v_unit
                                    when z.x <= 30 then '>15–30 ' || v_unit else '>30 ' || v_unit end end b,
                     case when v_rule = 'sla' then case when z.due is null then 0 when z.od <= 0 then 1 when z.od <= 1 then 2 when z.od <= 3 then 3 when z.od <= 7 then 4 when z.od <= 15 then 5 else 6 end
                          else case when z.x <= 1 then 1 when z.x <= 3 then 2 when z.x <= 7 then 3 when z.x <= 15 then 4 when z.x <= 30 then 5 else 6 end end o,
                     z.x a, z.loc, z.client, z.due, (z.due is not null and z.od > 0) past_due
                from (select ag1.*, case when v_rule = 'working' then ag1.aw else ag1.a end x from ag1) z),$q$);

    frag := $q$'oldest_days', (select round(max(a)::numeric, 1) from ag),$q$;
    n := (length(src) - length(replace(src, frag, ''))) / length(frag); if n <> 1 then raise exception 'api_ops oldest found % times', n; end if;
    src := replace(src, frag, frag || $q$
    'ageing_rule', v_rule,
    'ageing_cols', case v_rule when 'sla' then jsonb_build_array('Overdue by more than 3 days', 'Overdue by more than 15 days', 'Oldest (days since received)')
                               when 'working' then jsonb_build_array('Older than 7 working days', 'Older than 30 working days', 'Oldest (working days)')
                               else jsonb_build_array('Older than 7 days', 'Older than 30 days', 'Oldest (days)') end,
    'ageing_calendar', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'cases', n, 'past_due', pd) order by o), '[]')
                          from (select case when a <= 1 then '0–1 day' when a <= 3 then '>1–3 days' when a <= 7 then '>3–7 days' when a <= 15 then '>7–15 days' when a <= 30 then '>15–30 days' else '>30 days' end b,
                                       case when a <= 1 then 1 when a <= 3 then 2 when a <= 7 then 3 when a <= 15 then 4 when a <= 30 then 5 else 6 end o, count(*) n, count(*) filter (where due is not null and od > 0) pd
                                  from ag1 group by 1, 2) z),
    'ageing_compare', jsonb_build_object(
       'calendar', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'cases', n) order by o), '[]')
                      from (select case when a <= 1 then '0–1 day' when a <= 3 then '>1–3 days' when a <= 7 then '>3–7 days' when a <= 15 then '>7–15 days' when a <= 30 then '>15–30 days' else '>30 days' end b,
                                   case when a <= 1 then 1 when a <= 3 then 2 when a <= 7 then 3 when a <= 15 then 4 when a <= 30 then 5 else 6 end o, count(*) n from ag1 group by 1, 2) z),
       'working', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'cases', n) order by o), '[]')
                      from (select case when aw <= 1 then '0–1 working day' when aw <= 3 then '>1–3 working days' when aw <= 7 then '>3–7 working days' when aw <= 15 then '>7–15 working days' when aw <= 30 then '>15–30 working days' else '>30 working days' end b,
                                   case when aw <= 1 then 1 when aw <= 3 then 2 when aw <= 7 then 3 when aw <= 15 then 4 when aw <= 30 then 5 else 6 end o, count(*) n from ag1 group by 1, 2) z),
       'sla', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'cases', n) order by o), '[]')
                      from (select case when due is null then 'No due time' when od <= 0 then 'Not yet due' when od <= 1 then 'Overdue ≤1 day' when od <= 3 then 'Overdue >1–3 days' when od <= 7 then 'Overdue >3–7 days' when od <= 15 then 'Overdue >7–15 days' else 'Overdue >15 days' end b,
                                   case when due is null then 0 when od <= 0 then 1 when od <= 1 then 2 when od <= 3 then 3 when od <= 7 then 4 when od <= 15 then 5 else 6 end o, count(*) n from ag1 group by 1, 2) z)),$q$);

    frag := $q$Ageing = calendar days (not working days) from the case''s received time to the end of the last reported day, for cases still open; $q$;
    n := (length(src) - length(replace(src, frag, ''))) / length(frag); if n <> 1 then raise exception 'api_ops method found % times', n; end if;
    src := replace(src, frag, $q$' || case v_rule when 'working' then 'Ageing = working days (Mon–Sat, minus days an admin marked as non-working) from the case''s received time to the end of the last reported day, for cases still open; '
                                     when 'sla' then 'Ageing = time past the case''s own due time (Force1) at the end of the last reported day, for cases still open; "not yet due" cases are within their SLA; '
                                     else 'Ageing = calendar days (not working days) from the case''s received time to the end of the last reported day, for cases still open; ' end || 'Ageing rule chosen by an admin (Operations → Open cases by age); $q$);
    execute src;
  end if;

  -- 3) Ask Crux reads the calendar buckets (stable labels) whatever rule is selected
  select pg_get_functiondef('bi.ask_h_ops'::regproc) into src;
  if position('ageing_calendar' in src) = 0 then
    n := (length(src) - length(replace(src, $q$jsonb_array_elements(o->'ageing')$q$, ''))) / length($q$jsonb_array_elements(o->'ageing')$q$);
    if n < 1 then raise exception 'ask_h_ops ageing reference not found'; end if;
    execute replace(src, $q$jsonb_array_elements(o->'ageing')$q$, $q$jsonb_array_elements(coalesce(o->'ageing_calendar', o->'ageing'))$q$);
  end if;
end $do$;

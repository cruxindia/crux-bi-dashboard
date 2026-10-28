-- Applied to Supabase project via MCP on 20261028134752
-- bi_096d (28-Oct-2026): Operations scorecard from Force1 Case Wise (case grain, IST calendar days).
-- Daily sequence: opening backlog + received − completed = closing backlog (checked against an independent count of open cases);
-- open-case ageing in non-overlapping calendar-day buckets from the case's received time; completed-case TAT (received -> completed).
create or replace function bi.api_ops(p_month date, f jsonb default '{}'::jsonb) returns jsonb
 language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare m0 date; m1 date; v_asof date; r jsonb;
begin
  v_asof := (select (max(received_at) at time zone 'Asia/Kolkata')::date from bi.case_store);
  m0 := date_trunc('month', coalesce(p_month, v_asof))::date; m1 := least((m0 + interval '1 month - 1 day')::date, v_asof);
  with ops as materialized (
         select c.case_id, (c.received_at at time zone 'Asia/Kolkata')::date rd, (c.completed_at at time zone 'Asia/Kolkata')::date cd, c.location_id loc, c.client_code client,
                c.received_at recv, c.completed_at done, c.due_at due
           from bi.case_store c
          where c.received_at is not null and (c.completed_at is null or c.completed_at >= (m0 - interval '400 days'))
            and bi.loc_ok(c.location_id, c.recon_unit, f) and bi.fam_ok(c.client_code, f)),
       b0 as (select count(*) n from ops where rd < m0 and (cd is null or cd >= m0)),
       days as (select d::date d from generate_series(m0, m1, interval '1 day') d),
       inc as (select rd d, count(*) n from ops where rd between m0 and m1 group by 1),
       cls as (select cd d, count(*) n from ops where cd between m0 and m1 group by 1),
       seq as (select days.d, coalesce(inc.n, 0) incoming, coalesce(cls.n, 0) closed,
                      (select n from b0) + coalesce(sum(coalesce(inc.n, 0) - coalesce(cls.n, 0)) over (order by days.d rows between unbounded preceding and 1 preceding), 0) opening
                 from days left join inc on inc.d = days.d left join cls on cls.d = days.d),
       ag as (select case when a <= 1 then '0–1 day' when a <= 3 then '>1–3 days' when a <= 7 then '>3–7 days' when a <= 15 then '>7–15 days' when a <= 30 then '>15–30 days' else '>30 days' end b,
                     case when a <= 1 then 1 when a <= 3 then 2 when a <= 7 then 3 when a <= 15 then 4 when a <= 30 then 5 else 6 end o, a, loc, client, due
                from (select extract(epoch from ((m1 + 1)::timestamp at time zone 'Asia/Kolkata') - recv) / 86400.0 a, loc, client, due from ops where rd <= m1 and (cd is null or cd > m1)) z),
       tat as (select extract(epoch from done - recv) / 3600.0 h from ops where cd between m0 and m1 and done >= recv)
  select jsonb_build_object(
    'month', m0, 'as_of', m1, 'data_through', v_asof, 'opening_backlog', (select n from b0),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'opening', opening, 'incoming', incoming, 'closed', closed, 'closing', opening + incoming - closed) order by d), '[]') from seq),
    'received_mtd', (select coalesce(sum(incoming), 0) from seq), 'closed_mtd', (select coalesce(sum(closed), 0) from seq),
    'closing_backlog', (select opening + incoming - closed from seq order by d desc limit 1),
    'open_now_check', (select count(*) from ops where rd <= m1 and (cd is null or cd > m1)),
    'ageing', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'cases', n, 'share', round(n::numeric / nullif(t, 0), 4), 'past_due', pd) order by o), '[]')
                 from (select b, o, count(*) n, sum(count(*)) over () t, count(*) filter (where due is not null and due < ((m1 + 1)::timestamp at time zone 'Asia/Kolkata')) pd from ag group by 1, 2) z),
    'oldest_days', (select round(max(a)::numeric, 1) from ag),
    'over_7_days', (select count(*) from ag where o >= 4),
    'ageing_by_location', (select coalesce(jsonb_agg(jsonb_build_object('location_id', loc, 'location', (select label from bi.location where id = loc), 'open', n, 'over_7', o7, 'over_30', o30, 'oldest_days', od) order by n desc), '[]')
                             from (select loc, count(*) n, count(*) filter (where o >= 4) o7, count(*) filter (where o = 6) o30, round(max(a)::numeric, 1) od from ag group by 1) z),
    'tat', (select jsonb_build_object('completed', count(*), 'avg_hours', round(avg(h)::numeric, 1), 'median_hours', round((percentile_cont(0.5) within group (order by h))::numeric, 1),
                                      'p90_hours', round((percentile_cont(0.9) within group (order by h))::numeric, 1)) from tat),
    'method', 'Force1 Case Wise, one row per case, IST calendar days. Opening backlog = cases received before the day and not completed before it; closing = opening + received − completed. Ageing = calendar days from the case''s received time to the end of the last reported day, for cases still open; buckets do not overlap. TAT = received → completed for cases completed in the month (90th percentile = 90 % of cases finished within this time). The Zonal Tracker''s dated count is a different measure (business reported by the zone) and is shown beside it, never added.')
    into r;
  return r;
end $f$;

do $do$
declare d text; o text := $o$      when 'os_recon' then bi.api_os_recon()$o$;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_call fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$      when 'ops' then bi.api_ops(m, f)$n$);
end $do$;

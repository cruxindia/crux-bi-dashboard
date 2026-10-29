-- Applied to Supabase project via MCP on 20261029050111
-- bi_097e (29-Oct-2026)
-- (1) Operations API: per day also the median TAT of cases completed that day and the open cases older than 7 days at the end of the day (for the
--     Business Tracker sequence); ageing by client family; by location with past-due, mapped operations handler(s) and branch manager; SLA share.
-- (2) Roles: several people may share one role and scope ("additional"); edits keep the old row (withdrawn with the reason) and add a corrected row;
--     a preview shows the records an assignment covers before it is saved; person_role_at lists every active holder.
create or replace function bi.person_role_at(p_role text, p_loc int, p_code text, p_at date) returns text language sql stable set search_path to 'bi', 'public' as $f$
  select string_agg(distinct r.person, ', ') from bi.person_role r
   where r.active and r.role = p_role and r.location_id = p_loc and (r.client_code is null or r.client_code = p_code)
     and coalesce(r.valid_from, date '1900-01-01') <= p_at and coalesce(r.valid_to, date '2999-12-31') >= p_at
     and (p_code is null or r.client_code is not distinct from p_code
          or not exists (select 1 from bi.person_role r2 where r2.active and r2.role = p_role and r2.location_id = p_loc and r2.client_code = p_code
                           and coalesce(r2.valid_from, date '1900-01-01') <= p_at and coalesce(r2.valid_to, date '2999-12-31') >= p_at)) $f$;

create or replace function bi.person_role_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'list'); v_id bigint; v_from date := nullif(p->>'valid_from', '')::date; v_to date := nullif(p->>'valid_to', '')::date;
        clash bigint; old bi.person_role; v_loc int := nullif(p->>'location_id', '')::int; v_code text := nullif(p->>'client_code', ''); v_fam text;
begin
  if op = 'list' then
    return jsonb_build_object('rows', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'role', r.role, 'location_id', r.location_id, 'location', l.label, 'client_code', r.client_code,
             'person', r.person, 'valid_from', r.valid_from, 'valid_to', r.valid_to, 'active', r.active, 'note', r.note, 'created_by', r.created_by, 'created_at', r.created_at,
             'ended_by', r.ended_by, 'end_reason', r.end_reason) order by l.label, r.role, r.valid_from nulls first), '[]')
             from bi.person_role r join bi.location l on l.id = r.location_id where r.active or coalesce((p->>'include_ended')::boolean, false)));
  elsif op = 'preview' then
    if v_loc is null then raise exception 'Choose a location'; end if;
    v_fam := (select family from bi.client where code = v_code);
    return jsonb_build_object('location', (select label from bi.location where id = v_loc), 'client', v_code,
      'period', jsonb_build_object('from', v_from, 'to', v_to),
      'cases_received_in_period', (select count(*) from bi.case_store c where c.location_id = v_loc and (v_code is null or c.client_code = v_code)
                                     and (c.received_at at time zone 'Asia/Kolkata')::date between coalesce(v_from, date '2024-04-01') and coalesce(v_to, current_date)),
      'cases_open_now', (select count(*) from bi.case_store c where c.location_id = v_loc and (v_code is null or c.client_code = v_code) and c.completed_at is null),
      'receipts_in_period', (select round(coalesce(sum(a.amt), 0), 2) from bi.fin_attr a where a.kind = 'collected' and a.location_id = v_loc and (v_code is null or a.client_code = v_code or a.family = v_fam)
                               and a.m between date_trunc('month', coalesce(v_from, date '2024-04-01')) and coalesce(v_to, current_date)),
      'outstanding_now', (select round(coalesce(sum(a.amt), 0), 2) from bi.fin_attr a where a.kind = 'outstanding' and a.location_id = v_loc and (v_code is null or a.client_code = v_code or a.family = v_fam)
                            and a.upload_id = (select max(id) from bi.fin_upload where kind = 'outstanding' and status = 'committed')),
      'current_holders', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'role', r.role, 'person', r.person, 'client_code', r.client_code, 'valid_from', r.valid_from, 'valid_to', r.valid_to)), '[]')
                            from bi.person_role r where r.active and r.location_id = v_loc and (p->>'role' is null or r.role = p->>'role')
                              and r.client_code is not distinct from v_code
                              and coalesce(r.valid_from, date '1900-01-01') <= coalesce(v_to, date '2999-12-31') and coalesce(v_from, date '1900-01-01') <= coalesce(r.valid_to, date '2999-12-31')),
      'note', 'Records are counted at the location the dashboard gives them today. Saving changes nothing in the records; it only maps responsibility.');
  elsif op = 'add' then
    if coalesce(p->>'role', '') not in ('operations_handler', 'collections_owner') then raise exception 'Choose operations handler or collections owner'; end if;
    if nullif(btrim(p->>'person'), '') is null or v_loc is null then raise exception 'Location and person are required'; end if;
    if v_from is not null and v_to is not null and v_to < v_from then raise exception 'The end date is before the start date'; end if;
    if not coalesce((p->>'additional')::boolean, false) then
      select r.id into clash from bi.person_role r where r.active and r.role = p->>'role' and r.location_id = v_loc and r.client_code is not distinct from v_code
         and coalesce(r.valid_from, date '1900-01-01') <= coalesce(v_to, date '2999-12-31') and coalesce(v_from, date '1900-01-01') <= coalesce(r.valid_to, date '2999-12-31') limit 1;
      if clash is not null then
        -- only a later start may end the current holder; an earlier (backdated) start never rewrites the period of an existing assignment
        if coalesce((p->>'end_previous')::boolean, false) and v_from is not null
           and (select coalesce(valid_from, date '1900-01-01') from bi.person_role where id = clash) < v_from then
          update bi.person_role set valid_to = v_from - 1, ended_by = p_actor, ended_at = now(), end_reason = 'replaced from ' || v_from where id = clash;
        else raise exception 'Overlaps assignment % — tick "end the current one" (only for a later start date), mark it as an additional person, or change the dates', clash; end if;
      end if;
    end if;
    insert into bi.person_role(role, location_id, client_code, person, valid_from, valid_to, note, source, created_by)
    values (p->>'role', v_loc, v_code, btrim(p->>'person'), v_from, v_to,
            nullif(concat_ws('; ', nullif(p->>'note', ''), case when coalesce((p->>'additional')::boolean, false) then 'additional person for the same scope' end), ''), coalesce(p->>'source', 'admin'), p_actor)
    returning id into v_id;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'branch_role_add', 'person_role', v_id::text, p - 'admin_key');
    return jsonb_build_object('ok', true, 'id', v_id);
  elsif op = 'edit' then
    if length(coalesce(p->>'reason', '')) < 5 then raise exception 'A correction reason (5+ characters) is required'; end if;
    select * into old from bi.person_role where id = (p->>'id')::bigint and active;
    if old.id is null then raise exception 'Assignment not found or already withdrawn'; end if;
    update bi.person_role set active = false, ended_by = p_actor, ended_at = now(), end_reason = 'corrected: ' || (p->>'reason') where id = old.id;
    insert into bi.person_role(role, location_id, client_code, person, valid_from, valid_to, note, source, created_by)
    values (old.role, old.location_id, case when p ? 'client_code' then v_code else old.client_code end, coalesce(nullif(btrim(p->>'person'), ''), old.person),
            case when p ? 'valid_from' then v_from else old.valid_from end, case when p ? 'valid_to' then v_to else old.valid_to end,
            concat_ws('; ', old.note, 'replaces #' || old.id || ' (' || (p->>'reason') || ')'), 'admin correction', p_actor)
    returning id into v_id;
    if (select valid_to < valid_from from bi.person_role where id = v_id) then raise exception 'The end date is before the start date'; end if;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'branch_role_edit', 'person_role', v_id::text, (p - 'admin_key') || jsonb_build_object('replaces', old.id));
    return jsonb_build_object('ok', true, 'id', v_id, 'replaces', old.id);
  elsif op in ('end', 'withdraw') then
    if length(coalesce(p->>'reason', '')) < 5 then raise exception 'A reason (5+ characters) is required'; end if;
    if op = 'end' then
      update bi.person_role set valid_to = coalesce(v_to, current_date), ended_by = p_actor, ended_at = now(), end_reason = p->>'reason' where id = (p->>'id')::bigint and active;
    else
      update bi.person_role set active = false, ended_by = p_actor, ended_at = now(), end_reason = p->>'reason' where id = (p->>'id')::bigint and active;
    end if;
    if not found then raise exception 'Assignment not found or already withdrawn'; end if;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'branch_role_' || op, 'person_role', p->>'id', p - 'admin_key');
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'Unknown operation %', op;
end $f$;

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
       cls as (select cd d, count(*) n, percentile_cont(0.5) within group (order by extract(epoch from done - recv) / 3600.0) filter (where done >= recv) med from ops where cd between m0 and m1 group by 1),
       o7 as (select days.d, count(o.case_id) n from days left join ops o on o.rd <= days.d - 7 and (o.cd is null or o.cd > days.d) group by 1),
       seq as (select days.d, coalesce(inc.n, 0) incoming, coalesce(cls.n, 0) closed, round(cls.med::numeric, 1) med, coalesce(o7.n, 0) over7,
                      (select n from b0) + coalesce(sum(coalesce(inc.n, 0) - coalesce(cls.n, 0)) over (order by days.d rows between unbounded preceding and 1 preceding), 0) opening
                 from days left join inc on inc.d = days.d left join cls on cls.d = days.d left join o7 on o7.d = days.d),
       ag as (select case when a <= 1 then '0–1 day' when a <= 3 then '>1–3 days' when a <= 7 then '>3–7 days' when a <= 15 then '>7–15 days' when a <= 30 then '>15–30 days' else '>30 days' end b,
                     case when a <= 1 then 1 when a <= 3 then 2 when a <= 7 then 3 when a <= 15 then 4 when a <= 30 then 5 else 6 end o, a, loc, client, due,
                     (due is not null and due < ((m1 + 1)::timestamp at time zone 'Asia/Kolkata')) past_due
                from (select extract(epoch from ((m1 + 1)::timestamp at time zone 'Asia/Kolkata') - recv) / 86400.0 a, loc, client, due from ops where rd <= m1 and (cd is null or cd > m1)) z),
       tat as (select extract(epoch from done - recv) / 3600.0 h from ops where cd between m0 and m1 and done >= recv)
  select jsonb_build_object(
    'month', m0, 'as_of', m1, 'data_through', v_asof, 'opening_backlog', (select n from b0),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'opening', opening, 'incoming', incoming, 'closed', closed, 'closing', opening + incoming - closed,
                'median_tat_hours', med, 'open_over_7_days', over7) order by d), '[]') from seq),
    'received_mtd', (select coalesce(sum(incoming), 0) from seq), 'closed_mtd', (select coalesce(sum(closed), 0) from seq),
    'closing_backlog', (select opening + incoming - closed from seq order by d desc limit 1),
    'open_now_check', (select count(*) from ops where rd <= m1 and (cd is null or cd > m1)),
    'ageing', (select coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'cases', n, 'share', round(n::numeric / nullif(t, 0), 4), 'past_due', pd) order by o), '[]')
                 from (select b, o, count(*) n, sum(count(*)) over () t, count(*) filter (where past_due) pd from ag group by 1, 2) z),
    'past_due', (select count(*) filter (where past_due) from ag), 'with_due_date', (select count(*) filter (where due is not null) from ag),
    'oldest_days', (select round(max(a)::numeric, 1) from ag),
    'over_7_days', (select count(*) from ag where o >= 4),
    'ageing_by_location', (select coalesce(jsonb_agg(jsonb_build_object('location_id', loc, 'location', (select label from bi.location where id = loc), 'open', n, 'over_7', o7, 'over_30', o30,
                              'past_due', pd, 'oldest_days', od, 'handler', bi.person_role_at('operations_handler', loc, null, m1), 'branch_manager', bi.branch_manager_code_at(loc, null, m1)) order by n desc), '[]')
                             from (select loc, count(*) n, count(*) filter (where o >= 4) o7, count(*) filter (where o = 6) o30, count(*) filter (where past_due) pd, round(max(a)::numeric, 1) od from ag group by 1) z),
    'ageing_by_client', (select coalesce(jsonb_agg(jsonb_build_object('client_family', fam, 'open', n, 'over_7', o7, 'over_30', o30, 'past_due', pd, 'oldest_days', od) order by n desc), '[]')
                           from (select coalesce((select family from bi.client k where k.code = ag.client), ag.client, '(none)') fam, count(*) n, count(*) filter (where o >= 4) o7,
                                        count(*) filter (where o = 6) o30, count(*) filter (where past_due) pd, round(max(a)::numeric, 1) od from ag group by 1) z),
    'tat', (select jsonb_build_object('completed', count(*), 'avg_hours', round(avg(h)::numeric, 1), 'median_hours', round((percentile_cont(0.5) within group (order by h))::numeric, 1),
                                      'p90_hours', round((percentile_cont(0.9) within group (order by h))::numeric, 1)) from tat),
    'statuses', (select jsonb_object_agg(status, n) from (select status, count(*) n from bi.case_store group by 1) z),
    'method', 'Force1 Case Wise, one row per case, IST calendar days. Opening backlog = cases received before the day and not completed before it; closing = opening + received − completed. Force1 Case Wise carries only Pending, In Progress and Completed — there are no cancellation, reopen or transfer events to account for; a later upload that changes a case updates its history in place. Ageing = calendar days (not working days) from the case''s received time to the end of the last reported day, for cases still open; buckets do not overlap; "past due" = past the case''s due time. TAT = received → completed for cases completed in the period (90th percentile = 90 % of cases finished within this time). The Zonal Tracker''s dated count is a different measure (business reported by the zone) and is shown beside it, never added.')
    into r;
  return r;
end $f$;

-- Applied to Supabase project via MCP on 20261029150024
-- Wave 098: report calendar admin — list, set and withdraw (a withdrawn day keeps its row with active = false); every change is audited.
create or replace function bi.report_calendar_admin(p_actor text, p jsonb)
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'list'); d date := nullif(p->>'date', '')::date; rs jsonb; n int;
begin
  if op = 'list' then
    return jsonb_build_object('reasons', bi.report_calendar_reasons(), 'rows', (select coalesce(jsonb_agg(jsonb_build_object('date', report_date, 'reason', reason, 'reason_code', reason_code,
             'working_day', working_day, 'note', note, 'active', active, 'set_by', set_by, 'set_at', set_at, 'withdrawn_by', withdrawn_by, 'withdrawn_at', withdrawn_at) order by report_date desc), '[]')
             from bi.report_calendar_exception where active or coalesce((p->>'include_withdrawn')::boolean, false)));
  elsif op = 'set' then
    if d is null then raise exception 'Choose a date'; end if;
    if extract(isodow from d) = 7 then raise exception 'Sundays are never working days; nothing to mark'; end if;
    select x into rs from jsonb_array_elements(bi.report_calendar_reasons()) x where x->>'code' = p->>'reason_code';
    if rs is null then raise exception 'Choose a reason from the list'; end if;
    if (p->>'reason_code') in ('other_closed', 'other_open') and length(coalesce(btrim(p->>'note'), '')) < 3 then raise exception 'Describe the reason in the note'; end if;
    insert into bi.report_calendar_exception(report_date, reason, set_by, reason_code, working_day, note, active)
    values (d, rs->>'label', p_actor, rs->>'code', (rs->>'working_day')::boolean, nullif(btrim(p->>'note'), ''), true)
    on conflict (report_date) do update set reason = excluded.reason, set_by = excluded.set_by, set_at = now(), reason_code = excluded.reason_code,
      working_day = excluded.working_day, note = excluded.note, active = true, withdrawn_by = null, withdrawn_at = null;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'report_calendar_set', 'report_calendar_exception', d::text, p - 'admin_key');
    return jsonb_build_object('ok', true, 'date', d, 'reason', rs->>'label', 'working_day', (rs->>'working_day')::boolean);
  elsif op = 'withdraw' then
    if length(coalesce(p->>'reason', '')) < 5 then raise exception 'A reason (5+ characters) is required'; end if;
    select count(*) into n from bi.report_calendar_exception x where x.report_date = d and x.active;
    if n = 0 then raise exception 'That date is not marked'; end if;
    insert into bi.report_calendar_exception(report_date, reason, set_by)
    values (d, 'withdrawn', p_actor)
    on conflict (report_date) do update set active = false, withdrawn_by = p_actor, withdrawn_at = now(),
      note = concat_ws('; ', bi.report_calendar_exception.note, 'withdrawn: ' || (p->>'reason'));
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'report_calendar_withdraw', 'report_calendar_exception', d::text, p - 'admin_key');
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'Unknown operation %', op;
end $f$;

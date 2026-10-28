-- Applied to Supabase project via MCP on 20261022112036
-- bi_094a (22-Oct-2026): branch managers can be assigned to one client (code) at a location, e.g. BOM MSME separately from BOM retail.
-- Precedence for a location × client row: client row > client-family row > location row. Family-level look-ups list every manager
-- that handles part of the family there ("A, B"). Admin gains client-level assignment and a spelling correction ("rename").
alter table bi.branch_manager add column if not exists client_code text references bi.client(code);
comment on column bi.branch_manager.client_code is 'Optional single client at the location (wins over the family and the location row for that client).';

-- manager of one location × client on a date
create or replace function bi.branch_manager_code_at(p_loc int, p_code text, p_at date) returns text
language sql stable security definer set search_path to 'bi', 'public' as $$
  select m.manager from bi.branch_manager m
   where m.active and m.location_id = p_loc
     and (m.client_code = p_code
          or (m.client_code is null and (m.client_family is null
              or m.client_family = coalesce((select c.family from bi.client c where c.code = p_code), p_code))))
     and (m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to >= p_at)
   order by (m.client_code is not null) desc, (m.client_family is not null) desc, m.valid_from desc nulls last, m.id desc limit 1 $$;

-- manager(s) of one location × client family on a date: the family / location row plus any client rows inside the family
create or replace function bi.branch_manager_at(p_loc int, p_fam text, p_at date) returns text
language sql stable security definer set search_path to 'bi', 'public' as $$
  with base as (
    select m.manager from bi.branch_manager m
     where m.active and m.client_code is null and m.location_id = p_loc and (m.client_family is null or m.client_family = p_fam)
       and (m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to >= p_at)
     order by (m.client_family is not null) desc, m.valid_from desc nulls last, m.id desc limit 1),
  codes as (
    select m.manager from bi.branch_manager m join bi.client c on c.code = m.client_code
     where m.active and m.location_id = p_loc and coalesce(c.family, c.code) = p_fam
       and (m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to >= p_at))
  select string_agg(distinct x.manager, ', ' order by x.manager) from (select manager from base union select manager from codes) x $$;

create or replace function bi.branch_manager_admin(p_actor text, p jsonb)
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare op text := coalesce(p->>'op', 'list'); r bi.branch_manager; v_loc int; v_fam text; v_code text; v_from date; v_to date; v_name text; v_old text;
        v_id bigint; clash bigint; v_ended jsonb; n int;
begin
  if op = 'list' then
    return jsonb_build_object('rows', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'location_id', m.location_id, 'location', l.label, 'client_family', m.client_family,
              'client_code', m.client_code, 'client_label', cc.label,
              'manager', m.manager, 'valid_from', m.valid_from, 'valid_to', m.valid_to, 'active', m.active, 'note', m.note, 'source', m.source,
              'changed_by', m.changed_by, 'changed_at', m.changed_at,
              'current', m.active and (m.valid_from is null or m.valid_from <= current_date) and (m.valid_to is null or m.valid_to >= current_date))
              order by l.label, m.client_family nulls first, m.client_code nulls first, m.valid_from nulls first), '[]')
            from bi.branch_manager m join bi.location l on l.id = m.location_id left join bi.client cc on cc.code = m.client_code),
      'unassigned', (select coalesce(jsonb_agg(jsonb_build_object('location_id', l.id, 'location', l.label) order by l.label), '[]') from bi.location l
                     where not coalesce(l.is_rollup, false) and not exists (select 1 from bi.branch_manager m where m.active and m.location_id = l.id
                       and m.client_family is null and m.client_code is null and (m.valid_to is null or m.valid_to >= current_date))),
      'families', (select coalesce(jsonb_agg(distinct family order by family), '[]') from bi.client where family is not null),
      'clients', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label, 'family', family) order by family nulls last, label), '[]') from bi.client));
  elsif op = 'add' then
    v_loc := (p->>'location_id')::int; v_fam := nullif(btrim(coalesce(p->>'client_family', '')), ''); v_code := nullif(btrim(coalesce(p->>'client_code', '')), '');
    v_name := btrim(coalesce(p->>'manager', ''));
    v_from := nullif(p->>'valid_from', '')::date; v_to := nullif(p->>'valid_to', '')::date;
    if not exists (select 1 from bi.location where id = v_loc and not coalesce(is_rollup, false)) then raise exception 'choose a location'; end if;
    if v_code is not null then
      if not exists (select 1 from bi.client where code = v_code) then raise exception 'unknown client %', v_code; end if;
      v_fam := null;   -- a client row is narrower than its family
    end if;
    if v_fam is not null and not exists (select 1 from bi.client where family = v_fam) then raise exception 'unknown client family %', v_fam; end if;
    if length(v_name) < 2 or length(v_name) > 80 then raise exception 'manager name must be 2–80 characters'; end if;
    if v_to is not null and v_from is not null and v_to < v_from then raise exception 'valid to is before valid from'; end if;
    -- the current assignment for the same scope ends the day before the new one starts (only when asked); otherwise overlapping periods are refused
    if coalesce((p->>'end_previous')::boolean, false) and v_from is not null then
      select jsonb_agg(jsonb_build_object('id', m.id, 'valid_to_before', m.valid_to)) into v_ended from bi.branch_manager m
       where m.active and m.location_id = v_loc and m.client_family is not distinct from v_fam and m.client_code is not distinct from v_code
         and (m.valid_to is null or m.valid_to >= v_from) and (m.valid_from is null or m.valid_from < v_from);
      update bi.branch_manager set valid_to = v_from - 1, changed_by = p_actor, changed_at = now()
       where active and location_id = v_loc and client_family is not distinct from v_fam and client_code is not distinct from v_code
         and (valid_to is null or valid_to >= v_from) and (valid_from is null or valid_from < v_from);
    end if;
    select id into clash from bi.branch_manager where active and location_id = v_loc and client_family is not distinct from v_fam and client_code is not distinct from v_code
       and (valid_from is null or v_to is null or valid_from <= v_to) and (valid_to is null or v_from is null or valid_to >= v_from) limit 1;
    if clash is not null then raise exception 'overlaps assignment % for the same location and client — end it first or tick "end the current one"', clash; end if;
    insert into bi.branch_manager (location_id, client_family, client_code, manager, valid_from, valid_to, note, source, changed_by)
    values (v_loc, v_fam, v_code, v_name, v_from, v_to, nullif(left(p->>'note', 300), ''), coalesce(nullif(p->>'source', ''), 'admin'), p_actor) returning id into v_id;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'branch_manager_add', 'branch_manager', v_id::text,
      jsonb_build_object('location_id', v_loc, 'client_family', v_fam, 'client_code', v_code, 'valid_from', v_from, 'valid_to', v_to, 'ended_previous', v_ended));
    return jsonb_build_object('ok', true, 'id', v_id);
  elsif op = 'end' then
    v_id := (p->>'id')::bigint; v_to := (p->>'valid_to')::date;
    select * into r from bi.branch_manager where id = v_id and active;
    if not found then raise exception 'assignment % not found', v_id; end if;
    if v_to is null or (r.valid_from is not null and v_to < r.valid_from) then raise exception 'valid to must be on or after the start date'; end if;
    update bi.branch_manager set valid_to = v_to, changed_by = p_actor, changed_at = now() where id = v_id;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'branch_manager_end', 'branch_manager', v_id::text, jsonb_build_object('valid_to', v_to));
    return jsonb_build_object('ok', true);
  elsif op = 'withdraw' then
    -- an assignment entered by mistake is kept for audit but no longer used
    v_id := (p->>'id')::bigint;
    if length(btrim(coalesce(p->>'reason', ''))) < 5 then raise exception 'a reason (5+ characters) is required'; end if;
    update bi.branch_manager set active = false, note = left(coalesce(note || ' · ', '') || 'withdrawn: ' || btrim(p->>'reason'), 300), changed_by = p_actor, changed_at = now()
     where id = v_id and active;
    if not found then raise exception 'assignment % not found', v_id; end if;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'branch_manager_withdraw', 'branch_manager', v_id::text, jsonb_build_object('reason', left(p->>'reason', 300)));
    return jsonb_build_object('ok', true);
  elsif op = 'rename' then
    -- spelling correction of one name on every active row (the old spelling is kept in each row's note and in the audit row)
    v_old := btrim(coalesce(p->>'from', '')); v_name := btrim(coalesce(p->>'to', ''));
    if length(v_name) < 2 or length(v_name) > 80 then raise exception 'new name must be 2–80 characters'; end if;
    if v_old = v_name then raise exception 'the names are the same'; end if;
    update bi.branch_manager set manager = v_name, note = left(coalesce(note || ' · ', '') || 'spelling corrected from ' || v_old, 300), changed_by = p_actor, changed_at = now()
     where active and manager = v_old;
    get diagnostics n = row_count;
    if n = 0 then raise exception 'no active assignment named %', v_old; end if;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'branch_manager_rename', 'branch_manager', v_old, jsonb_build_object('rows', n));
    return jsonb_build_object('ok', true, 'rows', n);
  end if;
  raise exception 'unknown branch manager action %', op;
end $function$;

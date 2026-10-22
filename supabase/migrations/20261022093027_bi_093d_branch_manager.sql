-- Applied to Supabase project via MCP on 20261022093027
-- bi_093d (22-Oct-2026): branch managers as effective-dated assignments (location, optionally one client family at that location).
-- Names are loaded by an admin (Admin → Master data & mapping → Branch managers) or the owner; they are not part of this migration.
create table if not exists bi.branch_manager (
  id bigserial primary key,
  location_id int not null references bi.location(id),
  client_family text,                 -- null = the whole location; a family overrides the location-level manager for that client
  manager text not null check (length(btrim(manager)) between 2 and 80),
  valid_from date,                    -- null = no start date given (applies to all earlier periods)
  valid_to date,                      -- null = still assigned
  active boolean not null default true,
  source text not null default 'admin',
  note text,
  changed_by text not null default 'system',
  changed_at timestamptz not null default now(),
  check (valid_to is null or valid_from is null or valid_to >= valid_from));
create index if not exists branch_manager_loc on bi.branch_manager (location_id) where active;
alter table bi.branch_manager enable row level security;
comment on table bi.branch_manager is 'Branch manager per location (and optionally per client family at that location) with effective dates. Mapped responsibility, not proof of cause.';

create or replace function bi.branch_manager_at(p_loc int, p_fam text, p_at date) returns text
language sql stable security definer set search_path to 'bi', 'public' as $$
  select m.manager from bi.branch_manager m
   where m.active and m.location_id = p_loc and (m.client_family is null or m.client_family = p_fam)
     and (m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to >= p_at)
   order by (m.client_family is not null) desc, m.valid_from desc nulls last, m.id desc limit 1 $$;

create or replace function bi.branch_manager_admin(p_actor text, p jsonb) returns jsonb
language plpgsql security definer set search_path to 'bi', 'public' as $$
declare op text := coalesce(p->>'op', 'list'); r bi.branch_manager; v_loc int; v_fam text; v_from date; v_to date; v_name text; v_id bigint; clash bigint;
begin
  if op = 'list' then
    return jsonb_build_object('rows', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'location_id', m.location_id, 'location', l.label, 'client_family', m.client_family,
              'manager', m.manager, 'valid_from', m.valid_from, 'valid_to', m.valid_to, 'active', m.active, 'note', m.note, 'source', m.source,
              'changed_by', m.changed_by, 'changed_at', m.changed_at,
              'current', m.active and (m.valid_from is null or m.valid_from <= current_date) and (m.valid_to is null or m.valid_to >= current_date))
              order by l.label, m.client_family nulls first, m.valid_from nulls first), '[]')
            from bi.branch_manager m join bi.location l on l.id = m.location_id),
      'unassigned', (select coalesce(jsonb_agg(jsonb_build_object('location_id', l.id, 'location', l.label) order by l.label), '[]') from bi.location l
                     where not coalesce(l.is_rollup, false) and not exists (select 1 from bi.branch_manager m where m.active and m.location_id = l.id and m.client_family is null
                       and (m.valid_to is null or m.valid_to >= current_date))),
      'families', (select coalesce(jsonb_agg(distinct family order by family), '[]') from bi.client where family is not null));
  elsif op = 'add' then
    v_loc := (p->>'location_id')::int; v_fam := nullif(btrim(coalesce(p->>'client_family', '')), ''); v_name := btrim(coalesce(p->>'manager', ''));
    v_from := nullif(p->>'valid_from', '')::date; v_to := nullif(p->>'valid_to', '')::date;
    if not exists (select 1 from bi.location where id = v_loc and not coalesce(is_rollup, false)) then raise exception 'choose a location'; end if;
    if v_fam is not null and not exists (select 1 from bi.client where family = v_fam) then raise exception 'unknown client family %', v_fam; end if;
    if length(v_name) < 2 or length(v_name) > 80 then raise exception 'manager name must be 2–80 characters'; end if;
    if v_to is not null and v_from is not null and v_to < v_from then raise exception 'valid to is before valid from'; end if;
    -- the current assignment for the same scope ends the day before the new one starts (only when asked); otherwise overlapping periods are refused
    if coalesce((p->>'end_previous')::boolean, false) and v_from is not null then
      update bi.branch_manager set valid_to = v_from - 1, changed_by = p_actor, changed_at = now()
       where active and location_id = v_loc and client_family is not distinct from v_fam and (valid_to is null or valid_to >= v_from) and (valid_from is null or valid_from < v_from);
    end if;
    select id into clash from bi.branch_manager where active and location_id = v_loc and client_family is not distinct from v_fam
       and (valid_from is null or v_to is null or valid_from <= v_to) and (valid_to is null or v_from is null or valid_to >= v_from) limit 1;
    if clash is not null then raise exception 'overlaps assignment % for the same location and client — end it first or tick "end the current one"', clash; end if;
    insert into bi.branch_manager (location_id, client_family, manager, valid_from, valid_to, note, source, changed_by)
    values (v_loc, v_fam, v_name, v_from, v_to, nullif(left(p->>'note', 300), ''), 'admin', p_actor) returning id into v_id;
    insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'branch_manager_add', 'branch_manager', v_id::text,
      jsonb_build_object('location_id', v_loc, 'client_family', v_fam, 'valid_from', v_from, 'valid_to', v_to));
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
  end if;
  raise exception 'unknown branch manager action %', op;
end $$;

-- admin RPC dispatch (server-side key check stays the first statement of bi_admin)
do $do$
declare d text; o text := $o$    when 'kb' then return bi.kb_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');$o$;
        n text := $n$    when 'kb' then return bi.kb_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');
    when 'branch_manager' then return bi.branch_manager_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');$n$;
begin
  d := pg_get_functiondef('public.bi_admin'::regproc);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_admin fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;

-- revenue growth: branch manager per billing unit × client (managers of all member locations), grouping by manager, notes, method
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth_rev(date,jsonb,jsonb)'::regprocedure);
  o := array[
$o0$    select pr.*, om.basis org_basis,$o0$,
$o1$    from pr left join orgm om on om.unit_id = pr.unit_id and om.fam = pr.fam$o1$,
$o2$        'owner', r.owners, 'owner_changed', r.owners is distinct from r.owners_prev, 'owner_shared', position(',' in coalesce(r.owners, '')) > 0,$o2$,
$o3$                      when 'stakeholder' then coalesce(r.owners, '(not mapped)') when 'region' then coalesce(r.region, '(none)') end g,$o3$,
$o4$            union all select 'owner changed this month' where r.owners is distinct from r.owners_prev) z))$o4$,
$o5$      'owner', 'Owner = stakeholders mapped to the unit''s locations at the end of the billing month. Mapped responsibility, not proof of cause.',$o5$,
$o6$      'organic', 'Organic invoiced revenue = organic cases (the existing business-as-usual case model)$o6$];
  n := array[
$n0$    select pr.*, mg.mgr, mg.mgr_prev, mg.mgr_missing, om.basis org_basis,$n0$,
$n1$    from pr left join orgm om on om.unit_id = pr.unit_id and om.fam = pr.fam
      left join lateral (select string_agg(distinct q.m1, ', ' order by q.m1) mgr, string_agg(distinct q.m0, ', ' order by q.m0) mgr_prev, count(*) filter (where q.m1 is null) mgr_missing
                         from (select bi.branch_manager_at(lx, pr.fam, v_at) m1, bi.branch_manager_at(lx, pr.fam, (v_bm - interval '1 day')::date) m0
                               from unnest((select ua2.locs from ua ua2 where ua2.unit_id = pr.unit_id)) lx) q) mg on true$n1$,
$n2$        'owner', r.owners, 'owner_changed', r.owners is distinct from r.owners_prev, 'owner_shared', position(',' in coalesce(r.owners, '')) > 0,
        'branch_manager', r.mgr, 'branch_manager_prev', r.mgr_prev, 'branch_manager_changed', r.mgr is not null and r.mgr_prev is not null and r.mgr is distinct from r.mgr_prev,
        'branch_manager_shared', position(',' in coalesce(r.mgr, '')) > 0, 'branch_manager_missing', coalesce(r.mgr_missing, 0),$n2$,
$n3$                      when 'stakeholder' then coalesce(r.owners, '(not mapped)') when 'manager' then coalesce(r.mgr, '(not mapped)') when 'region' then coalesce(r.region, '(none)') end g,$n3$,
$n4$            union all select 'owner changed this month' where r.owners is distinct from r.owners_prev
            union all select 'branch manager changed this month (' || r.mgr_prev || ' → ' || r.mgr || ')' where r.mgr is not null and r.mgr_prev is not null and r.mgr is distinct from r.mgr_prev
            union all select 'branch managers differ across the combined locations' where position(',' in coalesce(r.mgr, '')) > 0) z))$n4$,
$n5$      'owner', 'Owner = stakeholders mapped to the unit''s locations at the end of the billing month. Branch manager = the manager assigned to the location, or to this client at the location, for the billing month (Admin → Master data & mapping). Both are mapped responsibility, not proof of cause.',$n5$,
$n6$      'organic', 'Organic invoiced revenue = organic cases (case model: 50% MoM, 40% QoQ with its trend, 10% YoY basis, × seasonal effect × working days)$n6$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_growth_rev fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  if position($q$('client', 'unit', 'zone', 'stakeholder', 'region')$q$ in d) = 0 then raise exception 'api_growth_rev group list not found'; end if;
  d := replace(d, $q$('client', 'unit', 'zone', 'stakeholder', 'region')$q$, $q$('client', 'unit', 'zone', 'stakeholder', 'manager', 'region')$q$);
  execute d;
end $do$;

-- cases growth: branch manager per location × client and grouping by manager
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_growth(date,jsonb,jsonb)'::regprocedure);
  o := array[
$o0$           bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm - interval '1 day')::date) owner_prev,$o0$,
$o1$        'owner', r.owner, 'owner_changed', r.owner is distinct from r.owner_prev,$o1$,
$o2$                when 'stakeholder' then coalesce(bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm + interval '1 month - 1 day')::date), '(not mapped)')$o2$];
  n := array[
$n0$           bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm - interval '1 day')::date) owner_prev,
           bi.branch_manager_at(k.location_id, k.fam, (v_cm + interval '1 month - 1 day')::date) mgr,
           bi.branch_manager_at(k.location_id, k.fam, (v_cm - interval '1 day')::date) mgr_prev,$n0$,
$n1$        'owner', r.owner, 'owner_changed', r.owner is distinct from r.owner_prev,
        'branch_manager', r.mgr, 'branch_manager_changed', r.mgr is not null and r.mgr_prev is not null and r.mgr is distinct from r.mgr_prev,$n1$,
$n2$                when 'stakeholder' then coalesce(bi.loc_attr_at(k.location_id, 'stakeholder', (v_cm + interval '1 month - 1 day')::date), '(not mapped)')
                when 'manager' then coalesce(bi.branch_manager_at(k.location_id, k.fam, (v_cm + interval '1 month - 1 day')::date), '(not mapped)')$n2$];
  for i in 1 .. array_length(o, 1) loop
    if (length(d) - length(replace(d, o[i], ''))) / length(o[i]) <> 1 then raise exception 'api_growth fragment % not found exactly once', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  if position($q$('client', 'location', 'zone', 'stakeholder', 'region')$q$ in d) = 0 then raise exception 'api_growth group list not found'; end if;
  d := replace(d, $q$('client', 'location', 'zone', 'stakeholder', 'region')$q$, $q$('client', 'location', 'zone', 'stakeholder', 'manager', 'region')$q$);
  execute d;
end $do$;

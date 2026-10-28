-- Applied to Supabase project via MCP on 20261028135304
-- bi_096f (28-Oct-2026): roles other than the branch manager — operations handler and collections owner — by location and (optionally) client,
-- with effective dates and an audit trail. Branch managers stay in bi.branch_manager (general manager = location row; client handler = client row);
-- a role row never replaces a branch manager. Names are entered by an administrator, never in a migration.
create table if not exists bi.person_role (
  id bigserial primary key, role text not null check (role in ('operations_handler', 'collections_owner')), location_id int not null references bi.location(id),
  client_code text references bi.client(code), person text not null, valid_from date, valid_to date, active boolean not null default true,
  note text, source text, created_by text, created_at timestamptz not null default now(), ended_by text, ended_at timestamptz, end_reason text,
  check (valid_to is null or valid_from is null or valid_to >= valid_from));
alter table bi.person_role enable row level security;

create or replace function bi.person_role_at(p_role text, p_loc int, p_code text, p_at date) returns text language sql stable set search_path to 'bi', 'public' as $f$
  select r.person from bi.person_role r
   where r.active and r.role = p_role and r.location_id = p_loc and (r.client_code is null or r.client_code = p_code)
     and coalesce(r.valid_from, date '1900-01-01') <= p_at and coalesce(r.valid_to, date '2999-12-31') >= p_at
   order by (r.client_code is not null) desc, r.valid_from desc nulls last limit 1 $f$;

create or replace function bi.person_role_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'list'); v_id bigint; v_from date := nullif(p->>'valid_from', '')::date; v_to date := nullif(p->>'valid_to', '')::date; clash bigint;
begin
  if op = 'list' then
    return jsonb_build_object('rows', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'role', r.role, 'location_id', r.location_id, 'location', l.label, 'client_code', r.client_code,
             'person', r.person, 'valid_from', r.valid_from, 'valid_to', r.valid_to, 'active', r.active, 'note', r.note) order by l.label, r.role, r.valid_from nulls first), '[]')
             from bi.person_role r join bi.location l on l.id = r.location_id where r.active or coalesce((p->>'include_ended')::boolean, false)));
  elsif op = 'add' then
    if coalesce(p->>'role', '') not in ('operations_handler', 'collections_owner') then raise exception 'Choose operations handler or collections owner'; end if;
    if nullif(btrim(p->>'person'), '') is null or nullif(p->>'location_id', '') is null then raise exception 'Location and person are required'; end if;
    select r.id into clash from bi.person_role r where r.active and r.role = p->>'role' and r.location_id = (p->>'location_id')::int and r.client_code is not distinct from nullif(p->>'client_code', '')
       and coalesce(r.valid_from, date '1900-01-01') <= coalesce(v_to, date '2999-12-31') and coalesce(v_from, date '1900-01-01') <= coalesce(r.valid_to, date '2999-12-31') limit 1;
    if clash is not null then
      if coalesce((p->>'end_previous')::boolean, false) and v_from is not null then
        update bi.person_role set valid_to = v_from - 1, ended_by = p_actor, ended_at = now(), end_reason = 'replaced' where id = clash;
      else raise exception 'Overlaps assignment %; tick "end the current one" or change the dates', clash; end if;
    end if;
    insert into bi.person_role(role, location_id, client_code, person, valid_from, valid_to, note, source, created_by)
    values (p->>'role', (p->>'location_id')::int, nullif(p->>'client_code', ''), btrim(p->>'person'), v_from, v_to, nullif(p->>'note', ''), coalesce(p->>'source', 'admin'), p_actor)
    returning id into v_id;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'branch_role_add', 'person_role', v_id::text, p - 'admin_key');
    return jsonb_build_object('ok', true, 'id', v_id);
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

do $do$
declare d text; o text := $o$    when 'branch_manager' then return bi.branch_manager_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');$o$;
begin
  d := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_admin fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$    when 'person_role' then return bi.person_role_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');$n$);
end $do$;

-- Applied to Supabase project via MCP on 20261113154918
-- wave 109c (13-Nov-2026, owner 20:59 IST): (1) which client in which location is run by a partner and which by Crux's own branch, since when and until when
-- (admin register with single edits and bulk upload); (2) people who do not work on Force1: monthly work reported on a template, so the gap between the
-- Zonal Tracker and Force1 case data can be filled and explained.

create or replace function bi.try_month(x text) returns date language sql immutable set search_path to 'bi', 'public' as $f$
  select date_trunc('month', coalesce(bi.try_date(x), bi.try_date('01-' || trim(x)), bi.try_date(trim(x) || '-01'),
         case when trim(x) ~ '^\d{4}-\d{1,2}$' then to_date(trim(x) || '-01', 'YYYY-MM-DD') end))::date
$f$;

create table if not exists bi.operating_model (
  id bigserial primary key,
  client_family text not null,
  client_code text,
  location_id int not null references bi.location(id),
  model text not null check (model in ('partner', 'self')),
  partner_name text,
  valid_from date not null,
  valid_to date,
  note text, source text, updated_by text, updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from));
create unique index if not exists operating_model_key on bi.operating_model (client_family, coalesce(client_code, ''), location_id, valid_from);
alter table bi.operating_model enable row level security;
revoke all on bi.operating_model from anon, authenticated;
comment on table bi.operating_model is 'Who runs each client in each Crux location: partner (franchise) or self (own branch), with start and end dates. A month counts under the model in force on its 15th. Wave 109c.';

create or replace function bi.model_on(p_client_code text, p_location_id int, p_day date) returns text language sql stable set search_path to 'bi', 'public' as $f$
  select o.model from bi.operating_model o
   where o.location_id = p_location_id and o.valid_from <= p_day and (o.valid_to is null or o.valid_to >= p_day)
     and o.client_family = coalesce((select family from bi.client where code = p_client_code), p_client_code)
     and (o.client_code is null or o.client_code = p_client_code)
   order by (o.client_code is not null) desc, o.valid_from desc limit 1
$f$;

create or replace function bi.operating_model_save(p_actor text, p_rows jsonb, p_dry boolean) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare x jsonb; rn int := 0; errs text[]; v_fam text; v_code text; v_loc int; v_model text; v_from date; v_to date; v_id bigint; o record;
        n_ins int := 0; n_upd int := 0; n_closed int := 0; bad jsonb := '[]'; res jsonb; by_model jsonb := '{}';
begin
  if jsonb_array_length(coalesce(p_rows, '[]')) > 5000 then raise exception 'At most 5,000 rows per upload'; end if;
  begin
    for x in select r from jsonb_array_elements(coalesce(p_rows, '[]')) r
             order by upper(trim(r->>'client')), upper(trim(r->>'location')), bi.try_date(r->>'from_date') nulls last loop
      rn := rn + 1; errs := '{}';
      v_fam := null; v_code := null;
      select family into v_fam from bi.client where upper(family) = upper(trim(x->>'client')) limit 1;
      if v_fam is null then
        select code, family into v_code, v_fam from bi.client where upper(code) = upper(trim(x->>'client')) or upper(label) = upper(trim(x->>'client')) limit 1;
      end if;
      if v_fam is null then
        select a.client_code, c.family into v_code, v_fam from bi.client_alias a join bi.client c on c.code = a.client_code where upper(a.alias) = upper(trim(x->>'client')) limit 1;
      end if;
      select id into v_loc from bi.location where not is_rollup and (upper(code) = upper(trim(x->>'location')) or upper(label) = upper(trim(x->>'location'))) limit 1;
      v_model := case when lower(coalesce(x->>'model', '')) ~ 'partner|franch|associate|vendor|agency' then 'partner'
                      when lower(coalesce(x->>'model', '')) ~ 'self|own|company|crux|direct' then 'self' end;
      v_from := bi.try_date(x->>'from_date'); v_to := bi.try_date(x->>'to_date');
      if v_fam is null then errs := errs || ('unknown client "' || coalesce(x->>'client', '') || '"'); end if;
      if v_loc is null then errs := errs || ('unknown location "' || coalesce(x->>'location', '') || '"'); end if;
      if v_model is null then errs := errs || 'model must be Partner or Own branch'::text; end if;
      if v_from is null then errs := errs || 'from_date (date) is required'::text; end if;
      if nullif(trim(x->>'to_date'), '') is not null and v_to is null then errs := errs || 'to_date is not a date'::text; end if;
      if v_to < v_from then errs := errs || 'to_date is before from_date'::text; end if;
      if cardinality(errs) = 0 then
        select id into v_id from bi.operating_model where client_family = v_fam and coalesce(client_code, '') = coalesce(v_code, '') and location_id = v_loc and valid_from = v_from;
        for o in select * from bi.operating_model where client_family = v_fam and coalesce(client_code, '') = coalesce(v_code, '') and location_id = v_loc
                   and id is distinct from v_id and valid_from <= coalesce(v_to, 'infinity'::date) and coalesce(valid_to, 'infinity'::date) >= v_from loop
          if o.valid_to is null and o.valid_from < v_from then
            update bi.operating_model set valid_to = v_from - 1, updated_by = p_actor, updated_at = now() where id = o.id; n_closed := n_closed + 1;
          else
            errs := errs || ('overlaps the ' || case o.model when 'partner' then 'partner' else 'own-branch' end || ' period ' || to_char(o.valid_from, 'DD-Mon-YYYY') || ' – ' ||
                             coalesce(to_char(o.valid_to, 'DD-Mon-YYYY'), 'open'));
          end if;
        end loop;
      end if;
      if cardinality(errs) > 0 then
        bad := bad || jsonb_build_object('row', coalesce((x->>'_row')::int, rn), 'client', x->>'client', 'key', coalesce(x->>'location', ''), 'errors', to_jsonb(errs));
        continue;
      end if;
      if v_id is not null then
        update bi.operating_model set model = v_model, partner_name = nullif(trim(x->>'partner_name'), ''), valid_to = v_to, note = nullif(trim(x->>'note'), ''),
               source = coalesce(nullif(trim(x->>'source'), ''), source), updated_by = p_actor, updated_at = now() where id = v_id;
        n_upd := n_upd + 1;
      else
        insert into bi.operating_model (client_family, client_code, location_id, model, partner_name, valid_from, valid_to, note, source, updated_by)
        values (v_fam, v_code, v_loc, v_model, nullif(trim(x->>'partner_name'), ''), v_from, v_to, nullif(trim(x->>'note'), ''), nullif(trim(x->>'source'), ''), p_actor);
        n_ins := n_ins + 1;
      end if;
      by_model := jsonb_set(by_model, array[v_model], to_jsonb(coalesce((by_model->>v_model)::int, 0) + 1));
    end loop;
    res := jsonb_build_object('kind', 'operating_model', 'dry_run', p_dry, 'rows', rn, 'valid', n_ins + n_upd, 'invalid', jsonb_array_length(bad),
             'inserted', n_ins, 'updated', n_upd, 'closed_previous', n_closed, 'by_client', by_model, 'errors', bad);
    if p_dry then raise exception using errcode = 'P0099', message = 'dry run'; end if;
  exception when sqlstate 'P0099' then
    res := res || jsonb_build_object('inserted', 0, 'updated', 0, 'would_insert', n_ins, 'would_update', n_upd);
  end;
  if not p_dry then
    insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'operating_model_save', 'operating_model', res - 'errors');
  end if;
  return res;
end $f$;

create or replace function bi.operating_model_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'list'); r jsonb;
begin
  if op = 'list' then
    return jsonb_build_object('rows', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'client_family', o.client_family, 'client_code', o.client_code,
             'client', coalesce(c.label, o.client_family || ' (all products)'), 'location_id', o.location_id, 'location', l.label, 'zone_group', l.zone_group,
             'model', o.model, 'partner_name', o.partner_name, 'valid_from', o.valid_from, 'valid_to', o.valid_to,
             'current', o.valid_from <= current_date and (o.valid_to is null or o.valid_to >= current_date), 'note', o.note, 'source', o.source,
             'updated_by', o.updated_by, 'updated_at', to_char(o.updated_at at time zone 'Asia/Kolkata', 'DD-Mon-YYYY HH24:MI'))
             order by l.zone_group, l.label, o.client_family, o.valid_from desc), '[]')
           from bi.operating_model o join bi.location l on l.id = o.location_id left join bi.client c on c.code = o.client_code));
  elsif op = 'save' then
    return bi.operating_model_save(p_actor, jsonb_build_array(p->'row'), false);
  elsif op = 'end' then
    update bi.operating_model set valid_to = bi.try_date(p->>'valid_to'), updated_by = p_actor, updated_at = now()
     where id = (p->>'id')::bigint and bi.try_date(p->>'valid_to') >= valid_from returning jsonb_build_object('id', id, 'valid_to', valid_to) into r;
    if r is null then raise exception 'End date must be a date on or after the start date'; end if;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'operating_model_end', 'operating_model', p->>'id', r);
    return r;
  elsif op = 'delete' then
    delete from bi.operating_model where id = (p->>'id')::bigint returning jsonb_build_object('id', id, 'client_family', client_family, 'location_id', location_id, 'model', model, 'valid_from', valid_from) into r;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'operating_model_delete', 'operating_model', p->>'id', r);
    return coalesce(r, '{}'::jsonb);
  end if;
  raise exception 'op must be list, save, end or delete';
end $f$;

create or replace function bi.api_operating_model(p_month date, f jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with mm as (select coalesce(p_month, (select max(month) from bi.v_month_business)) m),
  months as (select generate_series((select m from mm) - interval '5 months', (select m from mm), interval '1 month')::date m),
  b as (select mb.month, mb.location_id, mb.client_code, c.family, l.zone_group, l.label loc, mb.cases, mb.revenue,
               coalesce(bi.model_on(mb.client_code, mb.location_id, (mb.month + 14)), 'not set') model
          from bi.v_month_business mb join months on months.m = mb.month join bi.location l on l.id = mb.location_id
          left join bi.client c on c.code = mb.client_code
         where not l.is_rollup and bi.loc_ok(mb.location_id, l.recon_unit, f, mb.month) and bi.fam_ok(mb.client_code, f)),
  cur as (select o.*, l.label loc, l.zone_group from bi.operating_model o join bi.location l on l.id = o.location_id
           where o.valid_from <= current_date and (o.valid_to is null or o.valid_to >= current_date) and bi.loc_ok(o.location_id, l.recon_unit, f, (select m from mm))
             and (f->>'client_family' is null or o.client_family = f->>'client_family'))
  select jsonb_build_object('month', (select m from mm), 'rule', 'A month counts under the model in force on its 15th; a product-level entry wins over the family entry.',
    'register', jsonb_build_object('rows', (select count(*) from bi.operating_model), 'current', (select count(*) from cur),
       'current_partner', (select count(*) from cur where model = 'partner'), 'current_self', (select count(*) from cur where model = 'self'),
       'partner_locations', (select count(distinct location_id) from cur where model = 'partner'), 'self_locations', (select count(distinct location_id) from cur where model = 'self')),
    'trend', (select coalesce(jsonb_agg(jsonb_build_object('month', t.month, 'partner_cases', t.pc, 'self_cases', t.sc, 'not_set_cases', t.nc,
               'partner_revenue', t.pr, 'self_revenue', t.sr, 'not_set_revenue', t.nr) order by t.month), '[]')
              from (select month, sum(cases) filter (where model = 'partner') pc, sum(cases) filter (where model = 'self') sc, sum(cases) filter (where model = 'not set') nc,
                           round(sum(revenue) filter (where model = 'partner')) pr, round(sum(revenue) filter (where model = 'self')) sr, round(sum(revenue) filter (where model = 'not set')) nr
                      from b group by month) t),
    'by_zone', (select coalesce(jsonb_agg(z order by (z->>'revenue')::numeric desc nulls last), '[]') from (select jsonb_build_object('zone_group', zone_group,
                 'partner_cases', sum(cases) filter (where model = 'partner'), 'self_cases', sum(cases) filter (where model = 'self'), 'not_set_cases', sum(cases) filter (where model = 'not set'),
                 'partner_revenue', round(sum(revenue) filter (where model = 'partner')), 'self_revenue', round(sum(revenue) filter (where model = 'self')),
                 'not_set_revenue', round(sum(revenue) filter (where model = 'not set')), 'revenue', round(sum(revenue))) z
               from b where month = (select m from mm) group by zone_group) q),
    'by_location', (select coalesce(jsonb_agg(z order by z->>'zone_group', z->>'location'), '[]') from (select jsonb_build_object('location_id', location_id, 'location', loc, 'zone_group', zone_group,
                 'partner_clients', count(distinct family) filter (where model = 'partner'), 'self_clients', count(distinct family) filter (where model = 'self'),
                 'not_set_clients', count(distinct family) filter (where model = 'not set'),
                 'partner_cases', sum(cases) filter (where model = 'partner'), 'self_cases', sum(cases) filter (where model = 'self'), 'not_set_cases', sum(cases) filter (where model = 'not set'),
                 'partner_revenue', round(sum(revenue) filter (where model = 'partner')), 'self_revenue', round(sum(revenue) filter (where model = 'self')),
                 'not_set_revenue', round(sum(revenue) filter (where model = 'not set'))) z
               from b where month = (select m from mm) group by location_id, loc, zone_group) q),
    'current_rules', (select coalesce(jsonb_agg(jsonb_build_object('client_family', client_family, 'client_code', client_code, 'location', loc, 'zone_group', zone_group, 'model', model,
                 'valid_from', valid_from, 'valid_to', valid_to) order by zone_group, loc, client_family), '[]') from cur))
$f$;

create table if not exists bi.non_force1_work (
  id bigserial primary key,
  month date not null check (extract(day from month) = 1),
  location_id int not null references bi.location(id),
  client_family text,
  person_key text not null,
  employee_id text, person_name text not null,
  role text not null, engaged_as text,
  joined_on date, left_on date,
  cases_done int not null default 0 check (cases_done >= 0),
  points_done int not null default 0 check (points_done >= 0),
  working_days int check (working_days between 0 and 31),
  reason text, source text not null, updated_by text, updated_at timestamptz not null default now());
create unique index if not exists non_force1_work_key on bi.non_force1_work (month, location_id, person_key, coalesce(client_family, ''));
alter table bi.non_force1_work enable row level security;
revoke all on bi.non_force1_work from anon, authenticated;
comment on table bi.non_force1_work is 'Work of people who do not use Force1, reported monthly per person, location and (optionally) client on the template; fills the gap between the Zonal Tracker and Force1 case data. Names are admin-only. Wave 109c.';

create or replace function bi.non_force1_save(p_actor text, p_rows jsonb, p_dry boolean) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare res jsonb;
begin
  if jsonb_array_length(coalesce(p_rows, '[]')) > 20000 then raise exception 'At most 20,000 rows per upload'; end if;
  with src as (select o rn, x from jsonb_array_elements(coalesce(p_rows, '[]')) with ordinality t(x, o)),
  v as (select rn, x, bi.try_month(x->>'month') as month,
          (select id from bi.location l where not l.is_rollup and (upper(l.code) = upper(trim(x->>'location')) or upper(l.label) = upper(trim(x->>'location'))) limit 1) location_id,
          nullif(trim(x->>'name'), '') person_name, nullif(trim(x->>'employee_id'), '') employee_id, nullif(trim(x->>'role'), '') role, nullif(trim(x->>'engaged_as'), '') engaged_as,
          nullif(trim(x->>'client'), '') client_raw,
          case when nullif(trim(x->>'client'), '') is null or upper(trim(x->>'client')) in ('ALL', 'ALL CLIENTS') then null
               else coalesce((select family from bi.client where upper(family) = upper(trim(x->>'client')) limit 1),
                             (select family from bi.client where upper(code) = upper(trim(x->>'client')) or upper(label) = upper(trim(x->>'client')) limit 1)) end client_family,
          case when nullif(trim(x->>'cases_done'), '') is null then 0 when trim(x->>'cases_done') ~ '^\d+(\.0+)?$' then (trim(x->>'cases_done'))::numeric::int end cases_done,
          case when nullif(trim(x->>'points_done'), '') is null then 0 when trim(x->>'points_done') ~ '^\d+(\.0+)?$' then (trim(x->>'points_done'))::numeric::int end points_done,
          case when nullif(trim(x->>'working_days'), '') is null then null when trim(x->>'working_days') ~ '^\d+(\.0+)?$' then (trim(x->>'working_days'))::numeric::int end working_days,
          bi.try_date(x->>'joined_on') joined_on, bi.try_date(x->>'left_on') left_on, nullif(trim(x->>'reason_not_on_force1'), '') reason, nullif(trim(x->>'source'), '') source
        from src),
  e as (select v.*, coalesce('E:' || upper(employee_id), 'N:' || bi.norm(person_name)) person_key, array_remove(array[
          case when month is null then 'month is required (e.g. Nov-2026 or 01-11-2026)' end,
          case when month > date_trunc('month', current_date) then 'month is in the future' end,
          case when location_id is null then 'unknown location "' || coalesce(x->>'location', '') || '"' end,
          case when person_name is null then 'name is required' end,
          case when role is null then 'role is required (e.g. Field executive, Back office)' end,
          case when client_raw is not null and upper(client_raw) not in ('ALL', 'ALL CLIENTS') and client_family is null then 'unknown client "' || client_raw || '"' end,
          case when cases_done is null then 'cases_done must be a whole number' end,
          case when points_done is null then 'points_done must be a whole number' end,
          case when nullif(trim(x->>'working_days'), '') is not null and (working_days is null or working_days > 31) then 'working_days must be 0–31' end,
          case when nullif(trim(x->>'joined_on'), '') is not null and joined_on is null then 'joined_on is not a date' end,
          case when nullif(trim(x->>'left_on'), '') is not null and left_on is null then 'left_on is not a date' end,
          case when source is null then 'source is required (e.g. "Pune team sheet 14-Nov-2026")' end], null) errs from v),
  dup as (select e.month, e.location_id, e.person_key, coalesce(e.client_family, '') cf from e where e.month is not null and e.location_id is not null group by 1, 2, 3, 4 having count(*) > 1),
  e2 as (select e.*, case when exists (select 1 from dup d where d.month = e.month and d.location_id = e.location_id and d.person_key = e.person_key and d.cf = coalesce(e.client_family, ''))
                     then e.errs || 'same person, month, location and client repeated in this file'::text else e.errs end errs2 from e),
  ok as (select * from e2 where cardinality(errs2) = 0),
  ins as (insert into bi.non_force1_work (month, location_id, client_family, person_key, employee_id, person_name, role, engaged_as, joined_on, left_on, cases_done, points_done, working_days, reason, source, updated_by)
          select ok.month, ok.location_id, ok.client_family, ok.person_key, ok.employee_id, ok.person_name, ok.role, ok.engaged_as, ok.joined_on, ok.left_on, ok.cases_done, ok.points_done, ok.working_days, ok.reason, ok.source, p_actor
            from ok where not p_dry
          on conflict (month, location_id, person_key, coalesce(client_family, '')) do update set employee_id = excluded.employee_id, person_name = excluded.person_name, role = excluded.role,
            engaged_as = excluded.engaged_as, joined_on = excluded.joined_on, left_on = excluded.left_on, cases_done = excluded.cases_done, points_done = excluded.points_done,
            working_days = excluded.working_days, reason = excluded.reason, source = excluded.source, updated_by = excluded.updated_by, updated_at = now()
          returning (xmax = 0) inserted)
  select jsonb_build_object('kind', 'non_force1', 'dry_run', p_dry, 'rows', (select count(*) from e2), 'valid', (select count(*) from ok), 'invalid', (select count(*) from e2 where cardinality(errs2) > 0),
    'inserted', (select count(*) from ins where inserted), 'updated', (select count(*) from ins where not inserted),
    'already_in_master', (select count(*) from ok where exists (select 1 from bi.non_force1_work w where w.month = ok.month and w.location_id = ok.location_id and w.person_key = ok.person_key
                                                                 and coalesce(w.client_family, '') = coalesce(ok.client_family, ''))),
    'cases_reported', (select coalesce(sum(ok.cases_done), 0) from ok), 'points_reported', (select coalesce(sum(ok.points_done), 0) from ok),
    'by_client', (select coalesce(jsonb_object_agg(to_char(q.m, 'Mon-YYYY'), q.n), '{}') from (select ok.month m, count(*) n from ok group by 1) q),
    'errors', (select coalesce(jsonb_agg(jsonb_build_object('row', z.rn, 'client', z.x->>'name', 'key', coalesce(z.x->>'location', ''), 'errors', to_jsonb(z.errs2)) order by z.rn), '[]')
               from (select * from e2 where cardinality(e2.errs2) > 0 order by e2.rn limit 200) z))
  into res;
  if not p_dry then insert into bi.audit_log(actor, action, entity, detail) values (p_actor, 'non_force1_import', 'non_force1_work', res - 'errors'); end if;
  return res;
end $f$;

create or replace function bi.non_force1_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare op text := coalesce(p->>'op', 'list'); m date := bi.try_month(p->>'month'); n int;
begin
  if op = 'list' then
    return jsonb_build_object('month', m, 'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'month', w.month, 'location', l.label, 'zone_group', l.zone_group,
             'client_family', coalesce(w.client_family, 'All clients'), 'name', w.person_name, 'employee_id', w.employee_id, 'role', w.role, 'engaged_as', w.engaged_as,
             'cases_done', w.cases_done, 'points_done', w.points_done, 'working_days', w.working_days, 'joined_on', w.joined_on, 'left_on', w.left_on, 'reason', w.reason,
             'source', w.source, 'updated_by', w.updated_by, 'updated_at', to_char(w.updated_at at time zone 'Asia/Kolkata', 'DD-Mon-YYYY HH24:MI'))
             order by l.zone_group, l.label, w.person_name), '[]')
           from bi.non_force1_work w join bi.location l on l.id = w.location_id where m is null or w.month = m),
      'months', (select coalesce(jsonb_agg(jsonb_build_object('month', q.mo, 'rows', q.n, 'people', q.pp, 'cases', q.c) order by q.mo desc), '[]')
                   from (select w.month mo, count(*) n, count(distinct w.person_key) pp, sum(w.cases_done) c from bi.non_force1_work w group by w.month) q));
  elsif op = 'delete' then
    delete from bi.non_force1_work where id = (p->>'id')::bigint;
    get diagnostics n = row_count;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'non_force1_delete', 'non_force1_work', p->>'id', jsonb_build_object('deleted', n));
    return jsonb_build_object('deleted', n);
  end if;
  raise exception 'op must be list or delete';
end $f$;

create or replace function bi.api_force1_gap(p_month date, f jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with mm as (select coalesce(p_month, (select max(month) from bi.v_force_usage)) m),
  u as (select v.recon_unit, sum(v.tracker_cases) tracker, sum(v.force_cases) force1, bool_and(v.case_data_available) data_ok, max(v.tracker_as_of) as_of
          from bi.v_force_usage v where v.month = (select m from mm) and bi.loc_ok(null, v.recon_unit, f - 'location_id')
           and (f->>'client_family' is null or v.client_family = f->>'client_family') group by v.recon_unit),
  r as (select coalesce(l.recon_unit, l.label) recon_unit, count(distinct w.person_key) people, sum(w.cases_done) cases, sum(w.points_done) points,
               count(distinct w.person_key) filter (where w.role ~* 'field') field_people
          from bi.non_force1_work w join bi.location l on l.id = w.location_id
         where w.month = (select m from mm) and bi.loc_ok(w.location_id, l.recon_unit, f, w.month)
           and (f->>'client_family' is null or w.client_family = f->>'client_family' or w.client_family is null) group by 1),
  j as (select coalesce(u.recon_unit, r.recon_unit) unit, coalesce(u.tracker, 0) tracker, coalesce(u.force1, 0) force1, coalesce(r.people, 0) people, coalesce(r.field_people, 0) field_people,
               coalesce(r.cases, 0) reported, coalesce(r.points, 0) points, u.data_ok
          from u full join r on r.recon_unit = u.recon_unit)
  select jsonb_build_object('month', (select m from mm), 'as_of', (select max(as_of) from u),
    'method', 'Gap = Zonal Tracker cases − Force1 cases for the unit (never below zero). Reported = cases_done on the non-Force1 template for that month. Still open = gap − reported.',
    'totals', (select jsonb_build_object('tracker', sum(tracker), 'force1', sum(force1), 'gap', sum(greatest(tracker - force1, 0)), 'reported', sum(reported),
                 'still_open', sum(greatest(greatest(tracker - force1, 0) - reported, 0)), 'people', sum(people), 'points', sum(points)) from j),
    'units', (select coalesce(jsonb_agg(jsonb_build_object('unit', unit, 'tracker', tracker, 'force1', force1, 'gap', greatest(tracker - force1, 0), 'reported', reported,
               'still_open', greatest(greatest(tracker - force1, 0) - reported, 0), 'over_reported', greatest(reported - greatest(tracker - force1, 0), 0),
               'people', people, 'field_people', field_people, 'points', points,
               'covered_pct', case when tracker > 0 then round(100.0 * least(force1 + reported, tracker) / tracker, 1) end, 'case_data', data_ok)
               order by greatest(greatest(tracker - force1, 0) - reported, 0) desc), '[]') from j),
    'months_reported', (select coalesce(jsonb_agg(jsonb_build_object('month', q.mo, 'people', q.pp, 'cases', q.c) order by q.mo desc), '[]')
                          from (select w.month mo, count(distinct w.person_key) pp, sum(w.cases_done) c from bi.non_force1_work w group by w.month) q))
$f$;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $f$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $f$;
select pg_temp.patch('bi.master_import(text,jsonb)'::regprocedure, array[
  E'  else\n    raise exception ''kind must be branch or workforce'';',
  E'  elsif k = ''operating_model'' then   -- wave 109c\n    return bi.operating_model_save(p_actor, coalesce(p->''rows'', ''[]''), dry);\n  elsif k = ''non_force1'' then\n    return bi.non_force1_save(p_actor, coalesce(p->''rows'', ''[]''), dry);\n  else\n    raise exception ''kind must be branch, workforce, operating_model or non_force1'';'], array[1]);
select pg_temp.patch('public.bi_admin(text,jsonb)'::regprocedure, array[
  E'    when ''rate'' then return bi.rate_admin(',
  E'    when ''operating_model'' then return bi.operating_model_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');   -- wave 109c\n    when ''non_force1'' then return bi.non_force1_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');\n    when ''rate'' then return bi.rate_admin('], array[1]);
select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  E'      when ''branch_units'' then bi.api_branch_units(f, coalesce(p_args->''p'', ''{}''::jsonb))',
  E'      when ''branch_units'' then bi.api_branch_units(f, coalesce(p_args->''p'', ''{}''::jsonb))\n      when ''operating_model'' then bi.api_operating_model(m, f)   -- wave 109c\n      when ''force1_gap'' then bi.api_force1_gap(m, f)'], array[1]);

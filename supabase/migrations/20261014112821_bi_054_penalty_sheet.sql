-- Applied to Supabase project via MCP on 20261014112821
-- bi_054: Penalty sheet — admin-entered ₹ penalties with mandatory reason; date × location report (report only, not netted from revenue)
create table if not exists bi.penalty (
  id bigserial primary key,
  penalty_date date not null,
  location_id int not null references bi.location(id),
  client_code text,
  amount numeric(14,2) not null check (amount > 0),
  reason text not null check (length(trim(reason)) >= 5),
  reference text,
  created_by text not null,
  created_at timestamptz not null default now(),
  active boolean not null default true,
  voided_by text, voided_at timestamptz, void_reason text);
create index if not exists penalty_date_idx on bi.penalty(penalty_date);
alter table bi.penalty enable row level security;
comment on table bi.penalty is 'Penalties charged to Crux (₹), entered by admins with a reason. Reported only; never deducted from revenue. Voided entries are kept.';

create or replace function bi.penalty_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare op text := coalesce(p->>'op', 'list'); v_id bigint; v_date date; v_loc int; v_cli text; v_amt numeric; v_reason text := nullif(trim(p->>'reason'), ''); m date;
begin
  if op = 'add' then
    v_date := nullif(p->>'date', '')::date; v_loc := nullif(p->>'location_id', '')::int; v_amt := nullif(replace(p->>'amount', ',', ''), '')::numeric;
    v_cli := nullif(trim(p->>'client_code'), '');
    if v_date is null or v_date < date '2024-04-01' or v_date > (now() at time zone 'Asia/Kolkata')::date then raise exception 'Penalty date must be between 1-Apr-2024 and today'; end if;
    if v_loc is null or not exists (select 1 from bi.location where id = v_loc) then raise exception 'Choose a location'; end if;
    if v_cli is not null and not exists (select 1 from bi.client where code = v_cli) then raise exception 'Unknown client'; end if;
    if v_amt is null or v_amt <= 0 or v_amt >= 100000000 then raise exception 'Enter an amount above ₹0'; end if;
    if v_reason is null or length(v_reason) < 5 then raise exception 'A reason (5+ characters) is required — why was this penalty charged?'; end if;
    insert into bi.penalty(penalty_date, location_id, client_code, amount, reason, reference, created_by)
    values (v_date, v_loc, v_cli, round(v_amt, 2), v_reason, nullif(trim(p->>'reference'), ''), p_actor) returning id into v_id;
    insert into bi.audit_log(actor, action, entity, entity_key, detail)
    values (p_actor, 'penalty_add', 'penalty', v_id::text, jsonb_build_object('date', v_date, 'location_id', v_loc, 'client', v_cli, 'amount', v_amt, 'reason', v_reason, 'reference', p->>'reference'));
    return jsonb_build_object('added', true, 'id', v_id);
  elsif op = 'void' then
    v_id := (p->>'id')::bigint;
    if v_reason is null or length(v_reason) < 5 then raise exception 'A reason (5+ characters) is required to cancel a penalty'; end if;
    update bi.penalty set active = false, voided_by = p_actor, voided_at = now(), void_reason = v_reason where id = v_id and active returning id into v_id;
    if v_id is null then raise exception 'Penalty not found or already cancelled'; end if;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'penalty_void', 'penalty', v_id::text, jsonb_build_object('reason', v_reason));
    return jsonb_build_object('voided', true, 'id', v_id);
  elsif op = 'list' then
    m := date_trunc('month', coalesce(nullif(p->>'month', '')::date, (now() at time zone 'Asia/Kolkata')::date))::date;
    return jsonb_build_object('month', m, 'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'date', x.penalty_date, 'location_id', x.location_id, 'location', l.label,
              'client_code', x.client_code, 'client', coalesce(c.label, x.client_code), 'amount', x.amount, 'reason', x.reason, 'reference', x.reference, 'by', x.created_by, 'at', x.created_at,
              'active', x.active, 'voided_by', x.voided_by, 'void_reason', x.void_reason) order by x.penalty_date desc, x.id desc), '[]'::jsonb)
           from bi.penalty x join bi.location l on l.id = x.location_id left join bi.client c on c.code = x.client_code
           where x.penalty_date >= m and x.penalty_date < (m + interval '1 month')::date));
  end if;
  raise exception 'op must be add, void or list';
end $fn$;

create or replace function bi.api_penalty(p_month date, f jsonb default '{}'::jsonb) returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare m date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Kolkata')::date))::date; me date; latest date; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb); me := (m + interval '1 month - 1 day')::date;
  latest := coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = m), (select max(snapshot_date) from bi.zt_snapshot where snapshot_date <= me));
  with pen as (select x.*, l.recon_unit from bi.penalty x join bi.location l on l.id = x.location_id
               where x.active and x.penalty_date between m and me and bi.loc_ok(x.location_id, l.recon_unit, f, x.penalty_date)
                 and (x.client_code is null and f->>'client_family' is null or x.client_code is not null and bi.fam_ok(x.client_code, f))),
  base as (select z.location_id, min(z.sheet_row) ord from bi.zt_row z left join bi.location l on l.id = z.location_id
           where z.snapshot_date = latest and z.row_type = 'leaf' and z.location_id is not null and bi.loc_ok(z.location_id, l.recon_unit, f, latest) group by 1
           union select location_id, 100000 + location_id from pen where location_id not in (select location_id from bi.zt_row where snapshot_date = latest and row_type = 'leaf' and location_id is not null)),
  cols as (select l.id location_id, l.label, l.code, (select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(l.id, 'zone_group', latest)) zone, min(b.ord) ord
           from base b join bi.location l on l.id = b.location_id group by 1, 2, 3),
  dates as (select snapshot_date d from bi.zt_snapshot where report_month = m union select penalty_date from pen),
  cell as (select penalty_date d, location_id, sum(amount) amt, count(*) n from pen group by 1, 2),
  dd as (select d.d, (select coalesce(jsonb_object_agg(c.location_id::text, c.amt), '{}'::jsonb) from cell c where c.d = d.d) cells, coalesce((select sum(amt) from cell c where c.d = d.d), 0) total from dates d)
  select jsonb_build_object('month', m, 'latest_snapshot', latest, 'filters', f,
    'columns', (select coalesce(jsonb_agg(jsonb_build_object('location_id', location_id, 'label', label, 'code', code, 'zone', zone) order by ord), '[]') from cols),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'cells', cells, 'total', total) order by d), '[]') from dd),
    'summary', (select coalesce(jsonb_object_agg(location_id::text, jsonb_build_object('total', t, 'count', n)), '{}') from (select location_id, sum(amt) t, sum(n) n from cell group by 1) q),
    'grand', jsonb_build_object('total', (select coalesce(sum(amount), 0) from pen), 'count', (select count(*) from pen)),
    'by_client', (select coalesce(jsonb_agg(jsonb_build_object('client', coalesce(c.label, q.client_code, 'Not client-specific'), 'amount', q.t, 'count', q.n) order by q.t desc), '[]')
                  from (select client_code, sum(amount) t, count(*) n from pen group by 1) q left join bi.client c on c.code = q.client_code),
    'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'date', x.penalty_date, 'location', l.label, 'client', coalesce(c.label, x.client_code), 'amount', x.amount,
                  'reason', x.reason, 'reference', x.reference, 'by', regexp_replace(x.created_by, '^admin-key:', '')) order by x.penalty_date desc, x.id desc), '[]')
                from pen x join bi.location l on l.id = x.location_id left join bi.client c on c.code = x.client_code),
    'method', 'Penalties charged to Crux in ₹, entered by admins with the reason. Shown for reporting only — revenue is not reduced. Cancelled penalties are kept in the audit trail but not counted.')
  into res;
  return res;
end $fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''penalty''' in d) = 0 then
    d := replace(d, 'when ''branch_coverage'' then bi.api_branch_coverage(f)',
      'when ''branch_coverage'' then bi.api_branch_coverage(f)' || chr(10) || '      when ''penalty'' then bi.api_penalty(m, f)');
    d := replace(d, '  -- leaver names are HR data: admins only',
      '  -- penalty reasons and names of who entered them: admins only' || chr(10) ||
      '  if p_fn = ''penalty'' and not v_admin and jsonb_typeof(r->''entries'') = ''array'' then' || chr(10) ||
      '    r := jsonb_set(r, ''{entries}'', (select coalesce(jsonb_agg((x - ''reason'' - ''reference'' - ''by'') order by o), ''[]''::jsonb) from jsonb_array_elements(r->''entries'') with ordinality t(x, o)));' || chr(10) ||
      '    r := r || jsonb_build_object(''reasons_hidden'', true);' || chr(10) ||
      '  end if;' || chr(10) ||
      '  -- leaver names are HR data: admins only');
    if position('''penalty''' in d) = 0 or position('reasons_hidden' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;

do $do$
declare d text := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
begin
  if position('penalty_admin' in d) = 0 then
    d := replace(d, '    when ''matrix_no_report'' then',
      '    when ''penalty'' then return bi.penalty_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');' || chr(10) ||
      '    when ''matrix_no_report'' then');
    if position('penalty_admin' in d) = 0 then raise exception 'bi_admin patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_admin(text,jsonb) to anon, authenticated;

-- Applied to Supabase project via MCP on 20261014112220
-- bi_051: effective-dated rate changes (mid-month), day-wise revenue, admin API, commit hook
create table if not exists bi.rate_change (
  id bigserial primary key,
  location_id int not null references bi.location(id),
  client_code text not null,
  rate numeric not null check (rate > 0),
  wef date not null,
  reason text not null,
  created_by text not null,
  created_at timestamptz not null default now(),
  source text not null default 'admin',
  active boolean not null default true,
  ended_by text, ended_at timestamptz, end_reason text);
create unique index if not exists rate_change_active_uq on bi.rate_change(location_id, client_code, wef) where active;
alter table bi.rate_change enable row level security;
comment on table bi.rate_change is 'Rate per case for a location × client from a WEF date. Revenue = each report day''s added cases × the rate in force that day.';

create or replace function bi.rate_in_force(p_loc int, p_client text, p_d date) returns numeric language sql stable security definer set search_path to 'bi','public' as $fn$
  select rate from bi.rate_change where active and location_id = p_loc and client_code = p_client and wef <= p_d order by wef desc, id desc limit 1
$fn$;

create or replace function bi.rate_recompute(p_from date, p_loc int default null, p_client text default null) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare m0 date := date_trunc('month', coalesce(p_from, date '2024-04-01'))::date; n_rate int := 0; v_dates date[]; n_rev int := 0;
begin
  update bi.zt_row z set rate = x.r
  from (select z2.snapshot_date, z2.sheet_row, bi.rate_in_force(z2.location_id, z2.client_code, z2.snapshot_date) r
        from bi.zt_row z2
        where z2.row_type = 'leaf' and z2.snapshot_date >= m0
          and exists (select 1 from bi.rate_change c where c.active and c.location_id = z2.location_id and c.client_code = z2.client_code and c.wef <= z2.snapshot_date)) x
  where z.snapshot_date = x.snapshot_date and z.sheet_row = x.sheet_row and x.r is not null and z.rate is distinct from x.r;
  get diagnostics n_rate = row_count;

  with pairs as (select distinct location_id, client_code from bi.rate_change where active
                 union select p_loc, p_client where p_loc is not null and p_client is not null),
  leaf as (select z.snapshot_date d, z.sheet_row, z.location_id, z.client_code, date_trunc('month', z.snapshot_date)::date mon,
                  coalesce(z.mtd_cases, 0) e, z.target_cases t, coalesce(z.rate, 0) r
           from bi.zt_row z join pairs p on p.location_id = z.location_id and p.client_code = z.client_code
           where z.row_type = 'leaf' and z.snapshot_date >= m0),
  inc as (select leaf.*, e - coalesce(lag(e) over (partition by location_id, client_code, mon order by d), 0) de from leaf),
  cum as (select inc.*, sum(de * r) over (partition by location_id, client_code, mon order by d) g from inc),
  fin as (select d, sheet_row, round(g, 2) g,
                 round(case when t is null then null when e <= 0 then t * r when e < t then g + (t - e) * r else t * g / e end, 2) f from cum),
  upd as (update bi.zt_row z set revenue_actual = fin.g, revenue_target = fin.f, shortfall_revenue = fin.g - fin.f
          from fin where z.snapshot_date = fin.d and z.sheet_row = fin.sheet_row
            and (z.revenue_actual is distinct from fin.g or z.revenue_target is distinct from fin.f)
          returning z.snapshot_date)
  select array_agg(distinct snapshot_date), count(*) into v_dates, n_rev from upd;

  if v_dates is not null then
    update bi.zt_row z set revenue_actual = (select sum(l.revenue_actual) from bi.zt_row l where l.snapshot_date = z.snapshot_date and l.row_type = 'leaf' and l.sheet_row < z.sheet_row
           and l.sheet_row > coalesce((select max(p.sheet_row) from bi.zt_row p where p.snapshot_date = z.snapshot_date and p.row_type in ('location_total','zone_total') and p.sheet_row < z.sheet_row), 0))
     where z.snapshot_date = any(v_dates) and z.row_type = 'location_total';
    update bi.zt_row z set revenue_actual = (select sum(l.revenue_actual) from bi.zt_row l where l.snapshot_date = z.snapshot_date and l.row_type = 'leaf' and l.zone_group = z.zone_group)
     where z.snapshot_date = any(v_dates) and z.row_type = 'zone_total';
  end if;
  return jsonb_build_object('rates_updated', n_rate, 'revenue_rows_updated', n_rev, 'snapshots', coalesce(to_jsonb(v_dates), '[]'::jsonb));
end $fn$;

create or replace function bi.rate_admin(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare op text := coalesce(p->>'op', 'preview'); v_rate numeric; v_wef date; v_reason text := nullif(trim(p->>'reason'), '');
        tgt jsonb; bad jsonb; before jsonb; after jsonb; res jsonb; latest date := (select max(snapshot_date) from bi.zt_snapshot); n int; err text;
begin
  if op = 'history' then
    return (select jsonb_build_object('changes', coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'location_id', c.location_id, 'location', l.label, 'client_code', c.client_code,
              'client', coalesce((select label from bi.client where code = c.client_code), c.client_code), 'rate', c.rate, 'wef', c.wef, 'reason', c.reason, 'by', c.created_by, 'at', c.created_at,
              'source', c.source, 'active', c.active, 'ended_by', c.ended_by, 'end_reason', c.end_reason,
              'previous_rate', (select z.rate from bi.zt_row z where z.row_type = 'leaf' and z.location_id = c.location_id and z.client_code = c.client_code and z.snapshot_date < c.wef order by z.snapshot_date desc limit 1)
            ) order by c.wef desc, l.label), '[]'::jsonb))
            from bi.rate_change c join bi.location l on l.id = c.location_id
            where (p->>'month' is null or c.wef < (date_trunc('month', (p->>'month')::date) + interval '1 month')::date)
              and (p->>'month' is null or coalesce(c.ended_at::date, 'infinity'::date) >= date_trunc('month', (p->>'month')::date)::date)
              and (coalesce((p->>'include_ended')::boolean, false) or c.active));
  end if;

  if op = 'end' then
    if v_reason is null or length(v_reason) < 5 then raise exception 'A reason (5+ characters) is required'; end if;
    update bi.rate_change set active = false, ended_by = p_actor, ended_at = now(), end_reason = v_reason where id = (p->>'id')::bigint and active
      returning wef, location_id, client_code into v_wef, n, err;
    if v_wef is null then raise exception 'Rate change not found or already ended'; end if;
    update bi.zt_row z set rate = coalesce(bi.rate_in_force(z.location_id, z.client_code, z.snapshot_date),
             (select pr.rate from bi.zt_row pr where pr.row_type = 'leaf' and pr.location_id = z.location_id and pr.client_code = z.client_code and pr.snapshot_date < v_wef order by pr.snapshot_date desc limit 1), z.rate)
     where z.row_type = 'leaf' and z.location_id = n and z.client_code = err and z.snapshot_date >= v_wef;
    res := bi.rate_recompute(v_wef, n, err);
    err := null;
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values (p_actor, 'rate_change_end', 'rate_change', p->>'id', jsonb_build_object('reason', v_reason, 'recompute', res));
    return jsonb_build_object('ended', true, 'recompute', res);
  end if;

  v_rate := nullif(p->>'rate', '')::numeric; v_wef := nullif(p->>'wef', '')::date; tgt := coalesce(p->'rows', '[]'::jsonb);
  if v_rate is null or v_rate <= 0 then raise exception 'Enter a rate above 0'; end if;
  if v_wef is null or v_wef < date '2024-04-01' or v_wef > (now() at time zone 'Asia/Kolkata')::date + 62 then raise exception 'Effective date must be between 1-Apr-2024 and two months ahead'; end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'A reason (5+ characters) is required'; end if;
  if jsonb_array_length(tgt) = 0 or jsonb_array_length(tgt) > 500 then raise exception 'Choose between 1 and 500 rows'; end if;
  select jsonb_agg(x) into bad from jsonb_array_elements(tgt) x
   where not exists (select 1 from bi.zt_row z where z.snapshot_date = latest and z.row_type = 'leaf' and z.location_id = (x->>'location_id')::int and z.client_code = x->>'client_code');
  if bad is not null then raise exception 'Unknown location/client row(s): %', bad::text; end if;

  with t as (select (x->>'location_id')::int location_id, x->>'client_code' client_code from jsonb_array_elements(tgt) x),
  s as (select coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = date_trunc('month', v_wef)::date), latest) d)
  select jsonb_object_agg(t.location_id || '|' || t.client_code, jsonb_build_object('revenue', z.revenue_actual, 'revenue_target', z.revenue_target, 'rate', z.rate, 'mtd', z.mtd_cases))
    into before from t cross join s left join bi.zt_row z on z.snapshot_date = s.d and z.row_type = 'leaf' and z.location_id = t.location_id and z.client_code = t.client_code;

  begin
    insert into bi.rate_change(location_id, client_code, rate, wef, reason, created_by, source)
    select (x->>'location_id')::int, x->>'client_code', v_rate, v_wef, v_reason, p_actor, 'admin' from jsonb_array_elements(tgt) x
    on conflict (location_id, client_code, wef) where active do update set rate = excluded.rate, reason = excluded.reason, created_by = excluded.created_by, created_at = now(), source = 'admin';
    get diagnostics n = row_count;
    res := bi.rate_recompute(v_wef);
    with t as (select (x->>'location_id')::int location_id, x->>'client_code' client_code from jsonb_array_elements(tgt) x),
    s as (select coalesce((select max(snapshot_date) from bi.zt_snapshot where report_month = date_trunc('month', v_wef)::date), latest) d)
    select jsonb_agg(jsonb_build_object('location_id', t.location_id, 'location', l.label, 'client_code', t.client_code,
             'client', coalesce((select label from bi.client where code = t.client_code), t.client_code), 'as_of', s.d,
             'old_rate', before->(t.location_id || '|' || t.client_code)->'rate', 'new_rate', v_rate,
             'cases_before_wef', (select z.mtd_cases from bi.zt_row z where z.row_type = 'leaf' and z.location_id = t.location_id and z.client_code = t.client_code
                                   and z.snapshot_date < v_wef and z.snapshot_date >= date_trunc('month', v_wef)::date order by z.snapshot_date desc limit 1),
             'mtd', z.mtd_cases,
             'revenue_before', before->(t.location_id || '|' || t.client_code)->'revenue', 'revenue_after', z.revenue_actual,
             'revenue_target_before', before->(t.location_id || '|' || t.client_code)->'revenue_target', 'revenue_target_after', z.revenue_target) order by l.label, t.client_code)
      into after from t cross join s join bi.location l on l.id = t.location_id
      left join bi.zt_row z on z.snapshot_date = s.d and z.row_type = 'leaf' and z.location_id = t.location_id and z.client_code = t.client_code;
    if op <> 'apply' then raise exception 'rate_preview_rollback'; end if;
  exception when others then
    err := sqlerrm;
    if err <> 'rate_preview_rollback' then raise; end if;
  end;
  if op = 'apply' then
    insert into bi.audit_log(actor, action, entity, entity_key, detail)
    values (p_actor, 'rate_change', 'rate_change', v_wef::text, jsonb_build_object('rate', v_rate, 'wef', v_wef, 'reason', v_reason, 'rows', tgt, 'recompute', res, 'impact', after));
  end if;
  return jsonb_build_object('applied', op = 'apply', 'rows', jsonb_array_length(tgt), 'rate', v_rate, 'wef', v_wef, 'impact', coalesce(after, '[]'::jsonb),
    'rule', 'Revenue = each report day''s added cases × the rate in force on that day (cases reported before the effective date keep the old rate). Revenue target = cases achieved at the rates applied + remaining target cases at the current rate.');
end $fn$;

do $do$
begin
  if to_regprocedure('bi.matrix_commit_core(text,date,boolean,text)') is null then
    execute 'alter function bi.matrix_commit(text,date,boolean,text) rename to matrix_commit_core';
  end if;
end $do$;

create or replace function bi.matrix_commit(p_actor text, p_date date, p_ack_warnings boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'bi','public' as $fn$
declare r jsonb; prev date := bi.matrix_template(p_date); rc jsonb; n int := 0;
begin
  r := bi.matrix_commit_core(p_actor, p_date, p_ack_warnings, p_reason);
  if coalesce((r->>'committed')::boolean, false) then
    insert into bi.rate_change(location_id, client_code, rate, wef, reason, created_by, source)
    select z.location_id, z.client_code, dd.rate, p_date, 'Set in daily update table' || coalesce(': ' || nullif(trim(p_reason), ''), ''), p_actor, 'daily_table'
    from bi.zt_matrix_draft dd
    join bi.zt_row z on z.snapshot_date = p_date and z.row_type = 'leaf' and z.location_label = dd.location_label and z.client_label = dd.client_label
    where dd.snapshot_date = p_date and dd.committed_batch = (r->>'batch')::bigint and dd.rate is not null and z.location_id is not null and z.client_code is not null
      and dd.rate is distinct from coalesce(bi.rate_in_force(z.location_id, z.client_code, p_date - 1),
          (select pr.rate from bi.zt_row pr where pr.snapshot_date = prev and pr.row_type = 'leaf' and pr.location_id = z.location_id and pr.client_code = z.client_code limit 1))
    on conflict (location_id, client_code, wef) where active do update set rate = excluded.rate, reason = excluded.reason, created_by = excluded.created_by, created_at = now(), source = excluded.source;
    get diagnostics n = row_count;
    rc := bi.rate_recompute(p_date);
    r := r || jsonb_build_object('rate_changes_recorded', n, 'rates', rc);
  end if;
  return r;
end $fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
begin
  if position('rate_admin' in d) = 0 then
    d := replace(d, '    when ''matrix_no_report'' then',
      '    when ''rate'' then return bi.rate_admin(''admin-key:''||coalesce(nullif(trim(p->>''editor''),''''),''unnamed''), p - ''admin_key'');' || chr(10) ||
      '    when ''matrix_no_report'' then');
    if position('rate_admin' in d) = 0 then raise exception 'bi_admin patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_admin(text,jsonb) to anon, authenticated;

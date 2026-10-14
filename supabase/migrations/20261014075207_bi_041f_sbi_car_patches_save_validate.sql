-- Applied to Supabase project via MCP on 20261014075207
do $do$
declare d text := pg_get_functiondef('bi.api_tracker_sheet(date,jsonb,date,integer)'::regprocedure); d0 text := d;
begin
  d := replace(d, 'c.mtd_cases cm, c.revenue_actual cr, c.target_cases ct,',
                  'c.mtd_cases cm, c.revenue_actual cr, c.target_cases ct, coalesce((select pc.label from bi.client cc join bi.client pc on pc.code = cc.summary_under where cc.code = z.client_code), z.client_label) ck,');
  d := replace(d, 'and (lower(trim(coalesce(t.client_label, t.location_label))) = ''total'' or lower(trim(l.client_label)) = lower(trim(coalesce(t.client_label, t.location_label))))',
                  'and (lower(trim(coalesce(t.client_label, t.location_label))) = ''total'' or lower(trim(l.ck)) = lower(trim(coalesce(t.client_label, t.location_label))))');
  d := replace(d, '''exp'', z.expense_projected, ''m'', z.margin_after_expense, ''n'', z.col_n_value,', '');
  d := replace(d, '      ''Projected expense (L) and columns M/N are shown exactly as entered in the tracker; they are not calculated or verified by the dashboard.'',' || chr(10), '');
  d := replace(d, '''Monthly history columns come from the tracker''''s month history block (Actual MTD at month end, Actual Revenue, Actual Billing).''))',
                  '''Monthly history columns come from the tracker''''s month history block (Actual MTD at month end, Actual Revenue, Actual Billing).'',' || chr(10) ||
                  '      ''Client-wise block: SBI Car Loan+ is counted under SBI (product: Car Loan), as in the tracker.'', ' || chr(10) ||
                  '      ''Expense columns (L, M, N) are not shown: the business confirmed that data is incorrect.''))');
  if d = d0 or position('l.ck' in d) = 0 or position('''exp''' in d) > 0 or position('Projected expense' in d) > 0 or position('SBI Car Loan+ is counted' in d) = 0 then raise exception 'tracker_sheet patch incomplete'; end if;
  execute d;
end $do$;

do $do$
declare d text := pg_get_functiondef('bi.api_compare(jsonb,jsonb)'::regprocedure); d0 text := d;
begin
  d := replace(d, 'select s.*, l.label loc, l.tier, c.label cli, c.family fam,', 'select s.*, l.label loc, l.tier, coalesce(pc.label, c.label) cli, c.family fam,');
  d := replace(d, 'left join bi.client c on c.code = s.client_code', 'left join bi.client c on c.code = s.client_code left join bi.client pc on pc.code = c.summary_under');
  if d = d0 or position('pc.label' in d) = 0 then raise exception 'compare patch incomplete'; end if;
  execute d;
end $do$;

do $do$
declare d text := pg_get_functiondef('bi.api_zonal(date,jsonb)'::regprocedure); d0 text := d;
begin
  d := replace(d, '''client'',c.label,', '''client'',c.label,''client_group'',coalesce((select pc.label from bi.client pc where pc.code=c.summary_under),c.label),''product'',c.product,');
  if d = d0 then raise exception 'api_zonal patch made no change'; end if;
  execute d;
end $do$;

create or replace function bi.client_hierarchy_set(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare v_code text := upper(trim(p->>'code')); v_parent text := nullif(upper(trim(p->>'parent')),''); v_product text := nullif(trim(p->>'product'),''); o bi.client;
begin
  select * into o from bi.client where code = v_code;
  if o.code is null then raise exception 'Unknown client code %', v_code; end if;
  if v_parent is not null and not exists (select 1 from bi.client where code = v_parent) then raise exception 'Unknown parent client %', v_parent; end if;
  if v_parent = v_code then raise exception 'A client cannot be reported under itself'; end if;
  if coalesce(length(trim(p->>'reason')),0) < 5 then raise exception 'Reason must be at least 5 characters'; end if;
  update bi.client set summary_under = v_parent, product = v_product where code = v_code;
  insert into bi.audit_log(actor, action, entity, entity_key, detail)
  values (p_actor, 'client_hierarchy', 'client', v_code, jsonb_build_object('old_parent', o.summary_under, 'parent', v_parent, 'old_product', o.product, 'product', v_product, 'reason', p->>'reason'));
  return jsonb_build_object('ok', true, 'code', v_code, 'parent', v_parent, 'product', v_product);
end $fn$;

create or replace function bi.matrix_save(p_actor text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi','public' as $fn$
declare n int := 0; m int := 0;
begin
  insert into bi.zt_matrix_draft(snapshot_date, location_label, client_label, mtd_cases, target_cases, rate, entered_by)
  select (c->>'date')::date, c->>'location', c->>'client', nullif(c->>'mtd','')::numeric, nullif(c->>'target','')::numeric, nullif(c->>'rate','')::numeric, p_actor
  from jsonb_array_elements(coalesce(p->'cells','[]')) c
  where not exists (select 1 from bi.zt_snapshot s where s.snapshot_date = (c->>'date')::date)
     or exists (select 1 from bi.zt_reopen r where r.snapshot_date = (c->>'date')::date and r.active)
  on conflict (snapshot_date, location_label, client_label) do update
    set mtd_cases = case when excluded.mtd_cases is not null or (p->>'clear_blank')::boolean then excluded.mtd_cases else bi.zt_matrix_draft.mtd_cases end,
        target_cases = coalesce(excluded.target_cases, bi.zt_matrix_draft.target_cases),
        rate = coalesce(excluded.rate, bi.zt_matrix_draft.rate),
        entered_by = excluded.entered_by, entered_at = now(), committed_batch = null;
  get diagnostics n = row_count;
  insert into bi.zt_matrix_meta(snapshot_date, control_mtd, updated_by)
  select (x->>'date')::date, nullif(x->>'mtd','')::numeric, p_actor from jsonb_array_elements(coalesce(p->'control','[]')) x
  on conflict (snapshot_date) do update set control_mtd = excluded.control_mtd, updated_by = excluded.updated_by, updated_at = now();
  get diagnostics m = row_count;
  return jsonb_build_object('saved', n, 'controls', m);
end $fn$;

create or replace function bi.matrix_validate(p_date date) returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare reopened boolean := exists (select 1 from bi.zt_reopen where snapshot_date = p_date and active);
        prev date := bi.matrix_template(p_date);
        struct date; nxt date; sm boolean; ctl numeric; res jsonb;
begin
  struct := case when reopened then p_date else prev end;
  if struct is null then
    return jsonb_build_object('date', p_date, 'errors', 1, 'warnings', 0, 'issues', jsonb_build_array(jsonb_build_object('severity','error','rule','no_template')));
  end if;
  nxt := (select min(snapshot_date) from bi.zt_snapshot where snapshot_date > p_date and date_trunc('month', snapshot_date) = date_trunc('month', p_date));
  sm := prev is not null and date_trunc('month', prev) = date_trunc('month', p_date);
  ctl := (select control_mtd from bi.zt_matrix_meta where snapshot_date = p_date);
  with leaf as (select * from bi.zt_row where snapshot_date = struct and row_type = 'leaf'),
  pv as (select location_label, client_label, mtd_cases from bi.zt_row where snapshot_date = prev and row_type = 'leaf'),
  nx as (select location_label, client_label, mtd_cases from bi.zt_row where snapshot_date = nxt and row_type = 'leaf'),
  dr as (select * from bi.zt_matrix_draft where snapshot_date = p_date and committed_batch is null),
  j as (select l.location_label, l.client_label, case when sm then p.mtd_cases end prev, case when reopened then l.mtd_cases end old, d.mtd_cases cur, n.mtd_cases nextv,
               coalesce(d.target_cases, case when sm or reopened then l.target_cases end) tgt
        from leaf l left join pv p using (location_label, client_label) left join dr d using (location_label, client_label) left join nx n using (location_label, client_label)),
  chg as (select percentile_cont(0.9) within group (order by abs(mtd_cases - coalesce(src_prev_value, 0))) p90 from bi.zt_row where snapshot_date = prev and row_type = 'leaf'),
  issues as (
    select 'error' sev, 'missing_value' rule, location_label, client_label, prev::numeric pv, cur::numeric cv from j where cur is null
    union all select 'error', 'negative_value', location_label, client_label, prev, cur from j where cur < 0
    union all select 'error', 'unknown_row', d.location_label, d.client_label, null, d.mtd_cases from dr d
       where d.mtd_cases is not null and not exists (select 1 from leaf l where l.location_label = d.location_label and l.client_label = d.client_label)
    union all select 'error', 'already_loaded', null, null, null, null where not reopened and exists (select 1 from bi.zt_snapshot where snapshot_date = p_date)
    union all select 'warning', 'mtd_decreased', location_label, client_label, prev, cur from j where sm and cur < prev
    union all select 'warning', 'large_jump', location_label, client_label, prev, cur from j, chg where sm and cur - prev > greatest(25, 3 * coalesce(chg.p90, 0))
    union all select 'warning', 'above_next_snapshot', location_label, client_label, nextv, cur from j where nextv is not null and cur > nextv
    union all select 'warning', 'targets_missing', null, null, null, count(*)::numeric from j where tgt is null and not sm and not reopened having count(*) > 0
    union all select 'warning', 'control_total_mismatch', null, null, ctl, (select coalesce(sum(cur), 0) from j) where ctl is not null and ctl <> (select coalesce(sum(cur), 0) from j))
  select jsonb_build_object('date', p_date, 'template', prev, 'structure', struct, 'reopened', reopened, 'same_month', sm, 'next_snapshot', nxt, 'control_mtd', ctl,
    'rows_expected', (select count(*) from leaf), 'rows_entered', (select count(*) from dr where mtd_cases is not null),
    'total_mtd', (select sum(cur) from j), 'prev_total_mtd', (select sum(prev) from j), 'old_total_mtd', (select sum(old) from j),
    'changed_vs_committed', (select count(*) from j where reopened and cur is distinct from old),
    'errors', (select count(*) from issues where sev = 'error'), 'warnings', (select count(*) from issues where sev = 'warning'),
    'issues', coalesce((select jsonb_agg(jsonb_build_object('severity', sev, 'rule', rule, 'location', location_label, 'client', client_label, 'previous', pv, 'entered', cv)) from issues), '[]'),
    'changes', case when reopened then coalesce((select jsonb_agg(jsonb_build_object('location', location_label, 'client', client_label, 'old', old, 'new', cur)) from j where cur is distinct from old), '[]') end)
  into res;
  return res;
end $fn$;

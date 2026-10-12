-- Applied to Supabase project via MCP on 20261012103237

-- Expense & margin from the tracker's L/M/N block (interpretation documented in docs/DATA_DICTIONARY.md)
create or replace function bi.api_expense(p_snapshot date) returns jsonb
language sql stable security definer set search_path = bi, public as $$
with s as (select coalesce(p_snapshot, (select max(snapshot_date) from bi.zt_snapshot)) d),
r as (select z.* from bi.zt_row z, s where z.snapshot_date = s.d and z.row_type in ('leaf','zone_client_rollup','location_total','zone_total')),
blk as (select r.*, (select min(t.sheet_row) from r t where t.row_type in ('location_total','zone_total') and t.sheet_row >= r.sheet_row) total_row from r),
agg as (select total_row, sum(coalesce(expense_projected,0)) filter (where row_type in ('leaf','zone_client_rollup')) member_exp,
               min(location_id) filter (where row_type='leaf') any_loc from blk group by total_row),
t as (select r.sheet_row, r.row_type, r.location_label name, r.zone_group, r.revenue_actual revenue, r.expense_projected total_exp, a.member_exp, a.any_loc
      from r join agg a on a.total_row = r.sheet_row where r.row_type in ('location_total','zone_total')),
res as (select t.*, greatest(coalesce(total_exp,0), coalesce(member_exp,0)) expense,
               case when coalesce(total_exp,0) >= coalesce(member_exp,0) then 'total row' else 'sum of client rows' end basis,
               l.stakeholder, l.region from t left join bi.location l on l.id = t.any_loc)
select jsonb_build_object(
  'snapshot', (select d from s),
  'rows', coalesce((select jsonb_agg(jsonb_build_object(
      'level', case when row_type='zone_total' then 'zone' else 'location' end, 'name', name, 'zone', zone_group,
      'stakeholder', stakeholder, 'region', region, 'revenue', revenue, 'expense', nullif(expense,0),
      'margin', case when expense > 0 then revenue - expense end,
      'cover_2x', case when expense > 0 then revenue - 2*expense end,
      'expense_ratio', case when expense > 0 and revenue > 0 then round(expense/revenue, 4) end,
      'basis', basis) order by sheet_row) from res), '[]'::jsonb),
  'source_pan_india_expense', (select z.expense_projected from bi.zt_row z, s where z.snapshot_date=s.d and z.row_type='summary' and z.location_label ilike 'pan india'),
  'derived_total_expense', (select sum(expense) from res where row_type='zone_total' or not exists (select 1 from res z2 where z2.row_type='zone_total' and z2.zone_group = res.zone_group)),
  'note', 'L = projected monthly expense (salary+rent+other); M = revenue - expense; N (labelled YTD in source) = revenue - 2 x expense. Expense sits on inconsistent rows; per block the larger of total-row value and sum of client rows is used.');
$$;

-- Public, login-free read access. Admin features require an admin key (time-limited token, hash stored in bi.ingest_token).
create or replace function bi.admin_ok(p_key text) returns boolean
language sql stable security definer set search_path = bi, public as $$
  select bi.app_role() = 'admin' or bi.token_ok(p_key) $$;
revoke all on function bi.admin_ok(text) from public, anon, authenticated;

create or replace function public.bi_call(p_fn text, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare m date := nullif(p_args->>'month','')::date; f jsonb := coalesce(p_args->'filters','{}');
        v_admin boolean := bi.admin_ok(p_args->>'admin_key');
begin
  return case p_fn
    when 'meta' then bi.api_meta() || jsonb_build_object('role', case when v_admin then 'admin' else 'viewer' end)
    when 'overview' then bi.api_overview(m,f) when 'forecast' then bi.api_forecast(m,f)
    when 'zonal' then bi.api_zonal((p_args->>'snapshot')::date,f) when 'daily' then bi.api_daily(m,f)
    when 'monthly' then bi.api_monthly((p_args->>'from')::date,(p_args->>'to')::date,f,coalesce(p_args->>'group','total'))
    when 'force' then bi.api_force(m,f) when 'force_trend' then bi.api_force_trend(f)
    when 'case_tat' then bi.api_case_tat(m,f,coalesce(p_args->>'group','location'))
    when 'point_tat' then bi.api_point_tat(m,f,coalesce(p_args->>'group','category'))
    when 'manual_tat' then bi.api_manual_tat(m,f) when 'employees' then bi.api_employees(m,f) when 'insights' then bi.api_insights(m,f)
    when 'expense' then bi.api_expense(nullif(p_args->>'snapshot','')::date)
    when 'exceptions' then case when v_admin then bi.api_exceptions() else jsonb_build_object('error','admin key required') end
    when 'mapping_queue' then case when v_admin then bi.api_mapping_queue() else jsonb_build_object('error','admin key required') end
    else null end;
end $$;

create or replace function public.bi_admin(p_action text, p jsonb)
returns jsonb language plpgsql security definer set search_path = bi, public as $$
begin
  if not bi.admin_ok(p->>'admin_key') then raise exception 'admin key required' using errcode='42501'; end if;
  if p_action = 'verify' then return jsonb_build_object('ok', true); end if;
  if p_action = 'mapping_update' then return bi.api_mapping_update('admin-key', p - 'admin_key'); end if;
  if p_action = 'refresh_employees' then return jsonb_build_object('employees', bi.refresh_employee_classification()); end if;
  raise exception 'unknown action';
end $$;


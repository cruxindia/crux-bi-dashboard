-- Applied to Supabase project via MCP on 20261014070316
-- bi_038: Zonal Tracker replica (sheet order, recomputed subtotals, compare columns, monthly history) + period comparison API
create or replace function bi.api_tracker_sheet(p_snapshot date, f jsonb default '{}'::jsonb, p_cmp date default null, p_hist int default 6)
returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare s date; ps date; cs date; rm date; mumbai int; res jsonb; months date[];
begin
  s := coalesce(p_snapshot, (select max(snapshot_date) from bi.zt_snapshot));
  s := (select max(snapshot_date) from bi.zt_snapshot where snapshot_date <= s);
  if s is null then return jsonb_build_object('error','no tracker snapshot on or before this date'); end if;
  rm := date_trunc('month', s)::date;
  ps := (select max(snapshot_date) from bi.zt_snapshot where snapshot_date < s and snapshot_date >= rm);
  cs := case when p_cmp is not null then (select max(snapshot_date) from bi.zt_snapshot where snapshot_date <= p_cmp) end;
  mumbai := (select id from bi.location where code = 'MUMBAI');
  months := array(select (rm - (g || ' month')::interval)::date from generate_series(1, greatest(0, least(coalesce(p_hist,6), 24))) g);
  f := coalesce(f, '{}'::jsonb);

  with r as (select * from bi.zt_row where snapshot_date = s),
  leaf as (
    select z.sheet_row, z.zone_group, z.location_label, z.client_label, z.location_id, z.client_code, z.rate,
           z.target_cases tgt, z.mtd_cases mtd, z.revenue_target rtgt, z.revenue_actual rev, z.bd_revenue bd,
           z.expense_projected exp, z.margin_after_expense m, z.col_n_value n,
           case when ps is null then z.mtd_cases else z.mtd_cases - coalesce(p.mtd_cases, 0) end d,
           case when ps is null then z.revenue_actual else z.revenue_actual - coalesce(p.revenue_actual, 0) end dr,
           c.mtd_cases cm, c.revenue_actual cr, c.target_cases ct,
           bi.loc_attr_at(z.location_id, 'stakeholder', s) stk, bi.loc_attr_at(z.location_id, 'region', s) reg, l.tier,
           (bi.loc_ok(z.location_id, l.recon_unit, f, s) and bi.fam_ok(z.client_code, f)) ok
    from r z left join bi.location l on l.id = z.location_id
    left join lateral (select sum(x.mtd_cases) mtd_cases, sum(x.revenue_actual) revenue_actual from bi.zt_row x
                       where x.snapshot_date = ps and x.row_type = 'leaf' and x.location_id = z.location_id and x.client_code = z.client_code) p on true
    left join lateral (select sum(x.mtd_cases) mtd_cases, sum(x.revenue_actual) revenue_actual, sum(x.target_cases) target_cases from bi.zt_row x
                       where x.snapshot_date = cs and x.row_type = 'leaf' and x.location_id = z.location_id and x.client_code = z.client_code) c on cs is not null
    where z.row_type = 'leaf'),
  nl as (select * from r where row_type <> 'leaf'),
  lb as (select t.sheet_row, coalesce(max(x.sheet_row), 0) lo from nl t left join nl x on x.row_type in ('location_total','zone_total') and x.sheet_row < t.sheet_row
         where t.row_type = 'location_total' group by t.sheet_row),
  mem as (
    select sheet_row rr, sheet_row lr from leaf
    union all
    select b.sheet_row, l.sheet_row from lb b join leaf l on l.sheet_row < b.sheet_row and l.sheet_row > b.lo
    union all
    select t.sheet_row, l.sheet_row from nl t join leaf l on t.row_type = 'zone_total' and l.zone_group = t.zone_group
    union all
    select t.sheet_row, l.sheet_row from nl t join leaf l on t.row_type = 'zone_client_rollup' and l.zone_group = t.zone_group
       and lower(trim(l.client_label)) = lower(trim(t.client_label))
    union all
    select t.sheet_row, l.sheet_row from nl t join leaf l on t.row_type = 'summary' and (case lower(trim(t.location_label))
       when 'zone a' then l.tier = 'Zone A' when 'zone b' then l.tier = 'Zone B'
       when 'north zone' then l.reg = 'North' when 'south zone' then l.reg = 'South' when 'east zone' then l.reg = 'East' when 'west zone' then l.reg = 'West'
       when 'roi' then l.location_id is distinct from mumbai when 'pan india' then true else false end)
    union all
    select t.sheet_row, l.sheet_row from nl t join leaf l on t.row_type = 'client_summary'
       and lower(trim(l.client_label)) = lower(trim(coalesce(t.client_label, t.location_label)))
    union all
    select t.sheet_row, l.sheet_row from nl t join leaf l on t.row_type = 'stakeholder_summary'
       and (lower(trim(t.location_label)) = 'total' or lower(l.stk) = lower(regexp_replace(trim(t.location_label), '\s*''s?\s+zone\s*$', '', 'i')))),
  agg as (
    select m.rr, count(*) filter (where l.ok) k, count(*) members,
      sum(l.tgt) filter (where l.ok) tgt, sum(l.mtd) filter (where l.ok) mtd, sum(l.rtgt) filter (where l.ok) rtgt, sum(l.rev) filter (where l.ok) rev,
      sum(l.bd) filter (where l.ok) bd, sum(l.d) filter (where l.ok) d, sum(l.dr) filter (where l.ok) dr,
      sum(l.cm) filter (where l.ok) cm, sum(l.cr) filter (where l.ok) cr, sum(l.ct) filter (where l.ok) ct
    from mem m join leaf l on l.sheet_row = m.lr group by m.rr),
  hl as (
    select m.rr, mb.month, sum(mb.cases) c, sum(mb.revenue) v, sum(mb.billing) b
    from mem m join leaf l on l.sheet_row = m.lr and l.ok
    join bi.v_month_business mb on mb.location_id = l.location_id and mb.client_code = l.client_code and mb.month = any(months)
    group by m.rr, mb.month),
  h as (select rr, jsonb_object_agg(to_char(month, 'YYYY-MM'), jsonb_build_array(c, v, b)) h from hl group by rr),
  outr as (
    select z.sheet_row, jsonb_strip_nulls(jsonb_build_object(
      'r', z.sheet_row, 't', z.row_type, 'z', z.zone_group, 'loc', z.location_label, 'cli', z.client_label,
      'lid', z.location_id, 'cc', z.client_code, 'rate', z.rate,
      'stk', lf.stk, 'reg', lf.reg, 'tier', lf.tier,
      'tgt', a.tgt, 'mtd', a.mtd, 'rtgt', a.rtgt, 'rev', a.rev, 'ach', round(a.rev / nullif(a.rtgt, 0), 4), 'bd', a.bd, 'sf', a.rev - a.rtgt,
      'exp', z.expense_projected, 'm', z.margin_after_expense, 'n', z.col_n_value,
      'd', a.d, 'dr', a.dr, 'cm', a.cm, 'cr', a.cr, 'ct', a.ct,
      'stgt', case when z.row_type <> 'leaf' then z.target_cases end, 'smtd', case when z.row_type <> 'leaf' then z.mtd_cases end,
      'k', a.k, 'mem', a.members, 'h', h.h)) o
    from r z left join agg a on a.rr = z.sheet_row left join leaf lf on lf.sheet_row = z.sheet_row and z.row_type = 'leaf'
    left join h on h.rr = z.sheet_row
    where (z.row_type = 'leaf' and lf.ok) or (z.row_type <> 'leaf' and (coalesce(a.k, 0) > 0 or f = '{}'::jsonb)))
  select jsonb_build_object(
    'snapshot', s, 'report_month', rm, 'prev_snapshot', ps, 'compare_snapshot', cs, 'requested_compare', p_cmp,
    'history_months', (select coalesce(jsonb_agg(to_char(x, 'YYYY-MM') order by x desc), '[]') from unnest(months) x),
    'filters', f,
    'rows', coalesce((select jsonb_agg(o order by sheet_row) from outr), '[]'),
    'notes', jsonb_build_array(
      'Leaf rows are the tracker''s own values for this snapshot. Every subtotal, zone, region, client-wise and stakeholder total is recomputed from the leaf rows (the source sheet has some broken SUM ranges); where the source total differs, the source value is shown as a warning.',
      'Daily = this snapshot''s MTD minus the previous snapshot''s MTD in the same month (cases at every level; the source sheet shows revenue change on total rows).',
      'Projected expense (L) and columns M/N are shown exactly as entered in the tracker; they are not calculated or verified by the dashboard.',
      'Monthly history columns come from the tracker''s month history block (Actual MTD at month end, Actual Revenue, Actual Billing).'))
  into res;
  return res;
end $fn$;

create or replace function bi.api_compare(p jsonb, f jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'bi','public' as $fn$
declare ka text := coalesce(p->'a'->>'kind','snapshot'); kb text := coalesce(p->'b'->>'kind','snapshot');
        da date; db date; g text := coalesce(p->>'group','location'); cur date := (select max(report_month) from bi.zt_snapshot);
        la text; lb text; pa boolean := false; pb boolean := false; warn jsonb := '[]'; res jsonb;
begin
  f := coalesce(f, '{}'::jsonb);
  if g not in ('location','client','client_family','stakeholder','zone','region','tier','total') then g := 'location'; end if;
  if ka = 'month' then da := date_trunc('month', (p->'a'->>'date')::date)::date; pa := da >= cur; la := to_char(da,'Mon YYYY') || case when pa then ' (MTD)' else '' end;
  else da := (select max(snapshot_date) from bi.zt_snapshot where snapshot_date <= (p->'a'->>'date')::date); la := 'MTD as of ' || to_char(da,'DD-Mon-YYYY'); end if;
  if kb = 'month' then db := date_trunc('month', (p->'b'->>'date')::date)::date; pb := db >= cur; lb := to_char(db,'Mon YYYY') || case when pb then ' (MTD)' else '' end;
  else db := (select max(snapshot_date) from bi.zt_snapshot where snapshot_date <= (p->'b'->>'date')::date); lb := 'MTD as of ' || to_char(db,'DD-Mon-YYYY'); end if;
  if da is null or db is null then return jsonb_build_object('error','No tracker data for one of the selected periods'); end if;
  if ka <> kb then warn := warn || to_jsonb('Comparing a month total with a month-to-date snapshot is not like-for-like.'::text); end if;
  if ka = 'month' and kb = 'month' and pa <> pb then warn := warn || to_jsonb('One month is still in progress (month-to-date) and the other is complete — not like-for-like.'::text); end if;
  if ka = 'snapshot' and kb = 'snapshot' and extract(day from da) <> extract(day from db) then
    warn := warn || to_jsonb(format('Snapshots are on different days of the month (%s vs %s); MTD values are not like-for-like.', extract(day from da), extract(day from db))); end if;

  with src as (
    select 'a' side, z.location_id, z.client_code, z.target_cases tgt, z.mtd_cases cases, z.revenue_actual rev, null::numeric bill, da dt
      from bi.zt_row z where ka = 'snapshot' and z.snapshot_date = da and z.row_type = 'leaf'
    union all
    select 'a', mb.location_id, mb.client_code, mb.target_cases, mb.cases, mb.revenue, mb.billing, least(coalesce(mb.as_of, da), (da + interval '1 month - 1 day')::date)
      from bi.v_month_business mb where ka = 'month' and mb.month = da
    union all
    select 'b', z.location_id, z.client_code, z.target_cases, z.mtd_cases, z.revenue_actual, null, db
      from bi.zt_row z where kb = 'snapshot' and z.snapshot_date = db and z.row_type = 'leaf'
    union all
    select 'b', mb.location_id, mb.client_code, mb.target_cases, mb.cases, mb.revenue, mb.billing, least(coalesce(mb.as_of, db), (db + interval '1 month - 1 day')::date)
      from bi.v_month_business mb where kb = 'month' and mb.month = db),
  x as (
    select s.*, l.label loc, l.tier, c.label cli, c.family fam,
      bi.loc_attr_at(s.location_id,'stakeholder', s.dt) stk, bi.loc_attr_at(s.location_id,'region', s.dt) reg,
      (select zg.label from bi.zone_group zg where zg.code = bi.loc_attr_at(s.location_id,'zone_group', s.dt)) zn
    from src s join bi.location l on l.id = s.location_id left join bi.client c on c.code = s.client_code
    where bi.loc_ok(s.location_id, l.recon_unit, f, s.dt) and bi.fam_ok(s.client_code, f)),
  k as (
    select case g when 'location' then loc when 'client' then coalesce(cli, client_code) when 'client_family' then coalesce(fam, cli)
                  when 'stakeholder' then coalesce(stk,'(none)') when 'zone' then coalesce(zn,'(none)') when 'region' then coalesce(reg,'(none)')
                  when 'tier' then coalesce(tier,'(none)') else 'Total' end key, side, tgt, cases, rev, bill from x),
  gg as (
    select key,
      sum(cases) filter (where side='a') a_cases, sum(cases) filter (where side='b') b_cases,
      sum(rev) filter (where side='a') a_rev, sum(rev) filter (where side='b') b_rev,
      sum(tgt) filter (where side='a') a_tgt, sum(tgt) filter (where side='b') b_tgt,
      sum(bill) filter (where side='a') a_bill, sum(bill) filter (where side='b') b_bill
    from k group by key)
  select jsonb_build_object(
    'a', jsonb_build_object('kind', ka, 'date', da, 'label', la, 'partial', pa),
    'b', jsonb_build_object('kind', kb, 'date', db, 'label', lb, 'partial', pb),
    'group', g, 'filters', f, 'warnings', warn,
    'totals', (select jsonb_build_object('a_cases', sum(a_cases), 'b_cases', sum(b_cases), 'a_rev', sum(a_rev), 'b_rev', sum(b_rev), 'a_tgt', sum(a_tgt), 'b_tgt', sum(b_tgt),
                 'd_cases', coalesce(sum(a_cases),0) - coalesce(sum(b_cases),0), 'd_pct', round((coalesce(sum(a_cases),0) - coalesce(sum(b_cases),0)) / nullif(sum(b_cases),0), 4),
                 'd_rev', coalesce(sum(a_rev),0) - coalesce(sum(b_rev),0)) from gg),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'a_cases', a_cases, 'b_cases', b_cases, 'a_rev', a_rev, 'b_rev', b_rev, 'a_tgt', a_tgt, 'b_tgt', b_tgt,
                 'a_bill', a_bill, 'b_bill', b_bill, 'a_ach', round(a_cases / nullif(a_tgt,0), 4), 'b_ach', round(b_cases / nullif(b_tgt,0), 4),
                 'd_cases', coalesce(a_cases,0) - coalesce(b_cases,0), 'd_pct', round((coalesce(a_cases,0) - coalesce(b_cases,0)) / nullif(b_cases,0), 4),
                 'd_rev', coalesce(a_rev,0) - coalesce(b_rev,0))
               order by coalesce(a_cases,0) - coalesce(b_cases,0)) from gg where coalesce(a_cases,0) <> 0 or coalesce(b_cases,0) <> 0 or coalesce(a_tgt,0) <> 0 or coalesce(b_tgt,0) <> 0), '[]'),
    'method', 'Snapshot = cumulative MTD on the latest tracker snapshot on or before the date. Month = tracker month history (month-end Actual MTD, revenue, billing); the current month is month-to-date. Grouping uses the mapping in force on each period''s date. Values are never summed across snapshots.')
  into res;
  return res;
end $fn$;

do $do$
declare d text := pg_get_functiondef('public.bi_call'::regproc);
begin
  if position('''tracker_sheet''' in d) = 0 then
    d := replace(d, 'when ''branches'' then bi.api_branches(f)',
      'when ''branches'' then bi.api_branches(f)'||chr(10)||
      '      when ''tracker_sheet'' then bi.api_tracker_sheet(nullif(p_args->>''snapshot'','''')::date, f, nullif(p_args->>''compare'','''')::date, coalesce((p_args->>''history'')::int, 6))'||chr(10)||
      '      when ''compare'' then bi.api_compare(p_args, f)');
    if position('''tracker_sheet''' in d) = 0 then raise exception 'bi_call patch failed'; end if;
    execute d;
  end if;
end $do$;
grant execute on function public.bi_call(text,jsonb) to anon, authenticated;


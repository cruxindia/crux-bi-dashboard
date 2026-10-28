-- Applied to Supabase project via MCP on 20261028064411
-- bi_094i (28-Oct-2026): live checks of the branch-manager panel, client-level assignment and the expected-revenue measure,
-- recomputed from the base tables (no names in this file — checks are generic over the assignment table).
create or replace function bi.test_bm() returns table(test text, passed boolean, detail text)
language plpgsql security definer set search_path to 'bi', 'public' as $function$
declare B jsonb; G jsonb; v_asof date; v_m date; v_spm date; v_k int; x numeric; y numeric; z numeric; n1 int; n2 int; bb jsonb; v_bc date; v_rm date; v_os bigint; loc int;
begin
  B := bi.api_bm(null, '{}'::jsonb, '{}'::jsonb);
  v_m := (B->>'month')::date; v_asof := (B->>'as_of')::date; v_spm := (B->>'previous_month_snapshot')::date;
  -- 1 managers add up to the total, which equals the tracker month to date
  select sum((m->>'expected_revenue')::numeric) into x from jsonb_array_elements(B->'managers') m;
  select round(sum(revenue_actual)) into y from bi.v_zt_leaf z join bi.location l on l.id = z.location_id where z.snapshot_date = v_asof and not coalesce(l.is_rollup, false);
  test := 'M1 managers'' expected revenue adds up to the total = tracker revenue to date'; passed := abs(x - (B->'total'->>'expected_revenue')::numeric) <= jsonb_array_length(B->'managers') and abs((B->'total'->>'expected_revenue')::numeric - y) <= 1;
  detail := format('Σ managers %s · total %s · tracker %s (%s)', x, B->'total'->>'expected_revenue', y, v_asof); return next;
  -- 2 same working day last month
  select round(sum(revenue_actual)) into y from bi.v_zt_leaf z join bi.location l on l.id = z.location_id where z.snapshot_date = v_spm and not coalesce(l.is_rollup, false);
  test := 'M2 comparison = the previous month''s report on the same working day'; passed := abs((B->'total'->>'expected_revenue_prev_same_day')::numeric - y) <= 1
    and bi.workdays(date_trunc('month', v_spm)::date, v_spm) <= (B->>'workdays_elapsed')::int;
  detail := format('%s on %s (working day %s of the earlier month)', y, v_spm, bi.workdays(date_trunc('month', v_spm)::date, v_spm)); return next;
  -- 3 billing: manager rows + unallocated = invoices of the last completely billed month
  bb := bi.fin_billing_basis(); v_bc := (bb->>'last_complete')::date;
  select sum((m->>'billed_complete')::numeric) into x from jsonb_array_elements(B->'managers') m;
  select round(sum(basic)) into y from bi.fin_inv_month where inv_month = v_bc;
  z := coalesce((B->'finance'->'unallocated'->>('billed_' || to_char(v_bc, 'YYYY_MM')))::numeric, 0);
  test := 'M3 billed by manager + not attributable = invoices of the last completely billed month'; passed := abs(x + z - y) <= jsonb_array_length(B->'managers') + 1;
  detail := format('%s + %s vs %s (%s)', x, z, y, to_char(v_bc, 'Mon-YY')); return next;
  -- 4 collections of the receipt month
  v_rm := date_trunc('month', (bb->>'receipts_through')::date)::date;
  select sum((m->>'collected_current')::numeric) into x from jsonb_array_elements(B->'managers') m;
  select round(sum(amount)) into y from bi.fin_rcpt_agg where rcpt_month = v_rm and n > 0 and upload_id in (select id from bi.fin_upload where kind = 'collection' and status = 'committed');
  z := coalesce((B->'finance'->'unallocated'->>('collected_' || to_char(v_rm, 'YYYY_MM')))::numeric, 0);
  test := 'M4 collected by manager + not tied to a location = receipts of the month'; passed := abs(coalesce(x, 0) + z - y) <= jsonb_array_length(B->'managers') + 1;
  detail := format('%s + %s vs %s (%s to %s)', coalesce(x, 0), z, y, to_char(v_rm, 'Mon-YY'), bb->>'receipts_through'); return next;
  -- 5 outstanding of the latest workbook
  select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select sum((m->>'outstanding')::numeric) into x from jsonb_array_elements(B->'managers') m;
  select round(sum(os)) into y from bi.fin_os_agg where upload_id = v_os and n > 0;
  z := (select coalesce(sum(value::numeric), 0) from jsonb_each_text(B->'finance'->'unallocated') where key like 'outstanding%');
  test := 'M5 outstanding by manager + not attributable = latest outstanding workbook'; passed := abs(x + z - y) <= jsonb_array_length(B->'managers') + 1;
  detail := format('%s + %s vs %s', x, z, y); return next;
  -- 6 precedence: every active client row and family row is what the look-up returns inside its own dates
  select count(*), count(*) filter (where bi.branch_manager_code_at(m.location_id, coalesce(m.client_code, (select min(c.code) from bi.client c where c.family = m.client_family)),
           coalesce(m.valid_from, date '2025-01-01') + case when m.valid_to is not null and m.valid_from is not null then (m.valid_to - m.valid_from) / 2 else 0 end) = m.manager)
    into n1, n2 from bi.branch_manager m where m.active and (m.client_code is not null or m.client_family is not null)
     and not exists (select 1 from bi.branch_manager m2 where m2.active and m2.location_id = m.location_id and m2.client_code is not null and m.client_code is null
                       and m2.client_code = (select min(c.code) from bi.client c where c.family = m.client_family));
  test := 'M6 a client row wins over its family and location rows; a family row wins over the location row'; passed := n1 = n2; detail := format('%s of %s client / family rows returned by the look-up', n2, n1); return next;
  -- 7 no overlapping active assignments for the same scope
  select count(*) into n1 from bi.branch_manager a join bi.branch_manager b on a.id < b.id and a.active and b.active and a.location_id = b.location_id
    and a.client_family is not distinct from b.client_family and a.client_code is not distinct from b.client_code
    and coalesce(a.valid_from, date '1900-01-01') <= coalesce(b.valid_to, date '2999-12-31') and coalesce(b.valid_from, date '1900-01-01') <= coalesce(a.valid_to, date '2999-12-31');
  test := 'M7 no overlapping assignments for the same location and client scope'; passed := n1 = 0; detail := n1 || ' overlaps'; return next;
  -- 8 a location filter narrows the panel to that location only
  select z2.location_id into loc from bi.v_zt_leaf z2 where z2.snapshot_date = v_asof group by 1 order by sum(revenue_actual) desc limit 1;
  B := bi.api_bm(null, jsonb_build_object('location_id', loc), '{}'::jsonb);
  select sum((m->>'expected_revenue')::numeric) into x from jsonb_array_elements(B->'managers') m;
  select round(sum(revenue_actual)) into y from bi.v_zt_leaf where snapshot_date = v_asof and location_id = loc;
  test := 'M8 location filter: managers add up to that location''s tracker revenue'; passed := abs(x - y) <= jsonb_array_length(B->'managers'); detail := format('location %s: %s vs %s', loc, x, y); return next;
  -- 9 expected-revenue growth: month to date and the completed month equal the tracker
  G := bi.api_growth(null, '{}'::jsonb, '{"value": "revenue"}'::jsonb);
  select round(sum(revenue_actual)) into y from bi.v_zt_leaf z join bi.location l on l.id = z.location_id where z.snapshot_date = (G->>'as_of')::date and not coalesce(l.is_rollup, false);
  select round(sum(revenue)) into z from bi.v_month_business v join bi.location l on l.id = v.location_id where v.month = (G->>'completed_month')::date and not coalesce(l.is_rollup, false);
  test := 'M9 expected-revenue growth: month to date and completed month = tracker revenue'; passed := G->>'measure' = 'expected_revenue'
    and abs((G->'cards'->'mtd'->'current'->>'cases')::numeric - y) <= 1 and abs((G->'cards'->'mom'->'current'->>'cases')::numeric - z) <= 1;
  detail := format('MTD %s vs %s · %s %s vs %s', G->'cards'->'mtd'->'current'->>'cases', y, G->>'completed_month', G->'cards'->'mom'->'current'->>'cases', z); return next;
  -- 10 expected-revenue pairs add up to the card; beyond-organic identity
  select sum((p->>'cases')::numeric) into x from jsonb_array_elements(G->'pairs') p;
  test := 'M10 expected-revenue pairs add up to the month-on-month card; growth beyond organic = actual growth − organic growth';
  passed := abs(x - (G->'cards'->'mom'->'current'->>'cases')::numeric) <= 1
    and abs((G->'cards'->'mom'->'organic'->>'beyond_organic')::numeric - ((G->'cards'->'mom'->'organic'->>'actual_growth')::numeric - (G->'cards'->'mom'->'organic'->>'organic_growth')::numeric)) <= 2;
  detail := format('Σ pairs %s vs card %s', x, G->'cards'->'mom'->'current'->>'cases'); return next;
  -- 11 hand-overs: relative shift = own change ÷ rest-of-business change − 1, windows of at most 3 months on each side
  B := bi.api_bm(null, '{}'::jsonb, '{}'::jsonb);
  select count(*), count(*) filter (where (h->>'relative_shift_pct') is null or abs((h->>'relative_shift_pct')::numeric - ((1 + (h->>'revenue_shift_pct')::numeric) / (1 + (h->>'rest_of_business_shift_pct')::numeric) - 1)) <= 0.0002)
    into n1, n2 from jsonb_array_elements(B->'handovers') h
   where coalesce(jsonb_array_length(h->'months_before'), 0) <= 3 and coalesce(jsonb_array_length(h->'months_after'), 0) <= 3;
  test := 'M11 hand-over shift arithmetic and windows'; passed := n1 = jsonb_array_length(B->'handovers') and n1 = n2; detail := format('%s of %s hand-overs consistent', n2, jsonb_array_length(B->'handovers')); return next;
end $function$;

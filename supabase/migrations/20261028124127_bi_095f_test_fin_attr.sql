-- Applied to Supabase project via MCP on 20261028124127
-- bi_095f: checks for whole-line finance attribution (read-only)
create or replace function bi.test_fin_attr() returns table(test text, passed boolean, detail text) language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_os bigint; v_co bigint[]; x numeric; y numeric; z numeric; n1 int;
begin
  select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select coalesce(array_agg(id), '{}') into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  select sum(amt) into x from bi.fin_attr where kind = 'billed'; select sum(basic) into y from bi.fin_inv_month;
  test := 'F1 attributed invoices = invoice totals (all months)'; passed := abs(x - y) < 1; detail := format('%s vs %s', round(x), round(y)); return next;
  select sum(amt) into x from bi.fin_attr where kind = 'collected' and upload_id = any (v_co); select sum(amount) into y from bi.fin_rcpt_agg where upload_id = any (v_co);
  test := 'F2 attributed receipts = receipt totals'; passed := abs(x - y) < 1; detail := format('%s vs %s', round(x), round(y)); return next;
  select sum(amt) into x from bi.fin_attr where kind = 'outstanding' and upload_id = v_os; select sum(os) into y from bi.fin_os_agg where upload_id = v_os;
  test := 'F3 attributed outstanding = outstanding workbook'; passed := abs(x - y) < 1; detail := format('%s vs %s', round(x), round(y)); return next;
  select count(*) into n1 from bi.fin_attr a where a.amt <> 0 and a.client_code <> '' and not exists (select 1 from bi.client c where c.code = a.client_code);
  test := 'F4 every attributed client is a known client code (one client per line group)'; passed := n1 = 0; detail := n1 || ' unknown'; return next;
  select sum(amt) filter (where location_id > 0 and not exists (select 1 from bi.location l where l.id = location_id and l.is_rollup)), sum(amt) into x, y
    from bi.fin_attr where kind = 'collected' and upload_id = any (v_co) and m = (select max(m) from bi.fin_attr where kind = 'collected');
  test := 'F5 share of the latest receipt month tied to a location (information)'; passed := true; detail := format('%s of %s (%s%%)', round(x), round(y), round(100 * x / nullif(y, 0), 1)); return next;
end $f$;

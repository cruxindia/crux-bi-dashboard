-- Applied to Supabase project via MCP on 20261121074710
create or replace function bi.api_fin_sources(f jsonb default '{}'::jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  with sr as (select * from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1),
       ua as (select * from bi.fin_upload where kind = 'unadjusted' and status = 'committed' order by as_of desc, id desc limit 1),
       os as (select * from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1),
       locs as (select l.id from bi.location l where bi.fin_loc_ok(l.id, coalesce(f, '{}'::jsonb)) union select 0 where coalesce(f, '{}'::jsonb) - 'month' = '{}'::jsonb),
       reg as (select i.inv_month mo, sum(i.reg_basic) reg, sum(i.reg_n) reg_n, sum(i.traced_basic) traced, sum(i.untraced_basic) untraced, sum(i.untraced_n) untraced_n,
                      sum(i.reg_open_basic) reg_open, sum(i.open_basic) ledger_open, sum(i.settled_basic) settled, sum(i.basic) billed
                 from bi.fin_inv_month i where i.inv_n > 0 and i.location_id in (select id from locs) and (f->>'client_family' is null or i.family = f->>'client_family')
                  and i.inv_month between coalesce((select period_from from sr), date '2100-01-01') and coalesce((select period_to from sr), date '1900-01-01') group by 1),
       ut as (select t.status, t.location_id, t.bank, t.rcpt_month, t.n, t.amount, t.dup_n, t.dup_amount from bi.fin_unadj_txn t
               where t.upload_id = (select id from ua) and t.n > 0 and t.location_id in (select id from locs))
  select jsonb_build_object(
    'sales_register', (select jsonb_build_object('upload', sr.id, 'file', sr.file_name, 'as_of', sr.as_of, 'from', sr.period_from, 'to', sr.period_to,
        'billed', (select round(sum(reg)) from reg), 'invoices', (select sum(reg_n) from reg), 'traced', (select round(sum(traced)) from reg),
        'status_not_traced', (select round(sum(untraced)) from reg), 'status_not_traced_n', (select sum(untraced_n) from reg),
        'open_per_register', (select round(sum(reg_open)) from reg), 'open_per_ledger', (select round(sum(ledger_open)) from reg),
        'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'billed', round(reg), 'invoices', reg_n, 'traced', round(traced), 'status_not_traced', round(untraced),
                     'settled', round(settled), 'open_per_ledger', round(ledger_open), 'open_per_register', round(reg_open),
                     'realisation_traced', case when traced > 0 then round(settled / traced, 3) end, 'register_settled_share', case when reg > 0 then round(1 - reg_open / reg, 3) end) order by mo) from reg),
        'outstanding_used', false,
        'note', 'Billed revenue for these months comes from the register (each invoice once). Its "Actual Outstanding" and paid / pending remarks are not maintained ' ||
                '(they equal Net on most lines, also on lines marked paid), so receivables come from the outstanding workbook of ' || coalesce(to_char((select as_of from os), 'DD-Mon-YYYY'), '—') || '.',
        'issues', sr.controls->'issues') from sr),
    'unadjusted', (select jsonb_build_object('upload', ua.id, 'file', ua.file_name, 'as_of', ua.as_of, 'from', ua.period_from, 'to', ua.period_to,
        'total', (select round(sum(amount)) from ut), 'lines', (select sum(n) from ut),
        'in_receipts', (select round(sum(amount)) from ut where status = 'in_receipts'), 'before_receipts', (select round(sum(amount)) from ut where status = 'before_receipts'),
        'after_receipts', (select round(sum(amount)) from ut where status = 'after_receipts'), 'not_found', (select round(sum(amount)) from ut where status = 'not_found'),
        'repeated', (select round(sum(dup_amount)) from ut), 'location_not_identified', (select round(sum(amount)) from ut where location_id = 0),
        'by_location', (select jsonb_agg(x order by (x->>'amount')::numeric desc) from (select jsonb_build_object('location_id', ut.location_id, 'location', coalesce(l.label, 'Location not identified'),
                          'amount', round(sum(ut.amount)), 'lines', sum(ut.n), 'in_receipts', round(coalesce(sum(ut.amount) filter (where ut.status = 'in_receipts'), 0)),
                          'older_than_90_days', round(coalesce(sum(ut.amount) filter (where ut.rcpt_month < (date_trunc('month', ua.as_of) - interval '2 months')::date), 0))) x
                          from ut left join bi.location l on l.id = ut.location_id group by ut.location_id, l.label) q),
        'by_month', (select jsonb_agg(jsonb_build_object('month', rcpt_month, 'amount', a, 'in_receipts', ir) order by rcpt_month) from (select rcpt_month, round(sum(amount)) a, round(coalesce(sum(amount) filter (where status = 'in_receipts'), 0)) ir from ut group by 1) q),
        'note', 'Money already in the bank that is not yet applied to an invoice. It is part of cash collected (never added to it); "in receipts" = found in the receipt files by bank, amount and date ± 3 days.',
        'issues', ua.controls->'issues') from ua),
    'uploads', (select jsonb_agg(jsonb_build_object('upload', u.id, 'kind', u.kind, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status, 'committed_at', u.committed_at, 'notes', u.notes) order by u.id desc)
                  from (select * from bi.fin_upload where status in ('committed', 'superseded') order by id desc limit 12) u)) $f$;
revoke all on function bi.api_fin_sources(jsonb) from public, anon, authenticated;

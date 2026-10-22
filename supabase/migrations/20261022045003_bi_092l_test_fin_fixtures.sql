-- Applied to Supabase project via MCP on 20261022045003
-- bi_092l (22-Oct-2026): controlled finance fixtures, run through the real ingest (begin/stage/commit) and bi.fin_derive inside a
-- sub-transaction that is always undone. Real uploads are set aside inside the sub-transaction, so only fixture rows are derived.
-- Nothing persists: every insert/update (uploads, parts, maps, aggregates, audit rows) is rolled back before the results are returned.
create or replace function bi.test_fin_fixtures()
returns table(test text, passed boolean, detail text)
language plpgsql volatile security definer set search_path to 'bi', 'public' set statement_timeout to '170s' as $$
declare
  res jsonb := '[]'::jsonb; fx jsonb; f jsonb; rsp jsonb := '{}'::jsonb; b jsonb; c jsonb; d jsonb; v_id bigint; v_loc int; h text;
  n_before int; n_after int; agg_before numeric; agg_after numeric;
  lc jsonb := '["r","loc","im","ims","cl","br","inv","basic","gross","tds","net","partial","os","rk"]';
  rcols jsonb := '["r","loc","bank","rm","d","amt","cl","br","inv","basic","im","ims","h"]';
  L1 jsonb := '[1,"Fixture","2026-05",null,"ZZ Test Bank","BR1","ZZT-2605-001",10000,11800,200,11600,0,11600,null]';
  L2o jsonb := '[2,"Fixture","2026-05",null,"ZZ Test Bank","BR1","ZZT-2605-002",20000,23600,400,23200,0,23200,null]';
  L2p jsonb := '[2,"Fixture","2026-05",null,"ZZ Test Bank","BR1","ZZT-2605-002",20000,23600,400,23200,10000,13200,null]';
  L3 jsonb := '[3,"Fixture","2026-06",null,"ZZ Test Bank","BR1","ZZT-2606-003",5000,5900,100,5800,0,5800,null]';
  L4 jsonb := '[4,"Fixture","2026-06",null,"ZZ Test Bank","BR1","ZZT-2606-003",5000,5900,100,5800,0,5800,null]';
  R1 jsonb := '[1,"Fixture","HDFC","2026-06","2026-06-01",11600,"ZZ Test Bank","BR1","ZZT-2605-001",10000,"2026-05",null,"h1"]';
  R2 jsonb := '[2,"Fixture","HDFC","2026-06","2026-06-20",10000,"ZZ Test Bank","BR1","ZZT-2605-002",20000,"2026-05",null,"h2"]';
  R3 jsonb := '[3,"Fixture","HDFC","2026-06","2026-06-25",17700,"ZZ Test Bank","BR1","ZZT-2605-004",15000,"2026-05",null,"h3"]';
  R4 jsonb := '[4,null,"HDFC","2026-06","2026-06-28",5000,null,null,null,null,null,null,"h4"]';
  R5 jsonb := '[5,"Fixture","HDFC","2026-06","2026-06-29",2900,"ZZ Test Bank","BR1","ZZT-2606-003",5000,"2026-06",null,"h5"]';
  R6 jsonb := '[6,"Fixture","HDFC","2026-06","2026-06-29",2900,"ZZ Test Bank","BR1","ZZT-2606-003",5000,"2026-06",null,"h5"]';
  R7 jsonb := '[7,"Fixture","HDFC","2026-07","2026-07-20",13200,"ZZ Test Bank","BR1","ZZT-2605-002",20000,"2026-05",null,"h7"]';
  R3b jsonb := '[1,"Fixture","HDFC","2026-06","2026-06-25",17700,"ZZ Test Bank","BR1","ZZT-2605-004",15000,"2026-05",null,"h3"]';
  R8 jsonb := '[2,"Fixture","HDFC","2027-04","2027-04-10",5800,"ZZ Test Bank","BR1","ZZT-2606-003",5000,"2026-06",null,"h8"]';
begin
  select count(*), coalesce(sum(os), 0) into n_before, agg_before from bi.fin_os_agg;
  begin
    -- set the real uploads aside (undone at the end) and map the fixture series to one location
    update bi.fin_upload set status = 'superseded' where status = 'committed';
    select id into v_loc from bi.location where not coalesce(is_rollup, false) order by id limit 1;
    insert into bi.fin_loc_map (key_type, key, location_id, confidence, note, updated_by) values ('prefix', 'ZZT', v_loc, 'high', 'test fixture', 'test')
      on conflict (key_type, key) do update set location_id = excluded.location_id;
    insert into bi.fin_client_map (key, family, note, updated_by) values ('zz test bank', 'ZZTEST', 'test fixture', 'test')
      on conflict (key) do update set family = excluded.family;
    fx := jsonb_build_array(
      jsonb_build_object('name', 'OS1',  'kind', 'outstanding', 'as_of', '2026-06-30', 'sheet', 'Fixture', 'role', 'ledger', 'rows', jsonb_build_array(L1, L2o)),
      jsonb_build_object('name', 'OS2',  'kind', 'outstanding', 'as_of', '2026-07-15', 'sheet', 'Fixture', 'role', 'ledger',
                         'rows', jsonb_build_array(jsonb_set(L1, '{12}', '11000'), L2p, L3, L4)),
      jsonb_build_object('name', 'OS2C', 'kind', 'outstanding', 'as_of', '2026-07-15', 'sheet', 'Fixture', 'role', 'ledger', 'rows', jsonb_build_array(L1, L2p, L3, L4)),
      jsonb_build_object('name', 'C1', 'kind', 'collection', 'as_of', '2026-06-30', 'period_from', '2026-04-01', 'sheet', 'HDFC', 'role', 'bank', 'rows', jsonb_build_array(R1, R2, R3, R4, R5, R6)),
      jsonb_build_object('name', 'C2', 'kind', 'collection', 'as_of', '2026-07-31', 'period_from', '2026-04-01', 'sheet', 'HDFC', 'role', 'bank', 'rows', jsonb_build_array(R1, R2, R3, R4, R5, R6, R7)),
      jsonb_build_object('name', 'C3', 'kind', 'collection', 'as_of', '2027-04-30', 'period_from', '2027-04-01', 'sheet', 'HDFC', 'role', 'bank', 'rows', jsonb_build_array(R3b, R8)),
      -- re-saved copy of OS2C (new file bytes, same rows): caught at commit by the server's content hash
      jsonb_build_object('name', 'DUPC', 'kind', 'outstanding', 'as_of', '2026-07-15', 'sheet', 'Fixture', 'role', 'ledger', 'rows', jsonb_build_array(L1, L2p, L3, L4)));
    for f in select * from jsonb_array_elements(fx) loop
      b := bi.fin_ingest_as('test-fixture', 'begin', jsonb_build_object('kind', f->>'kind', 'file_hash', encode(sha256(convert_to('fixture:' || (f->>'name'), 'UTF8')), 'hex'),
                            'file_name', 'fixture_' || (f->>'name') || '.xlsx', 'as_of', f->>'as_of', 'period_from', f->>'period_from'));
      v_id := (b->>'upload_id')::bigint;
      perform bi.fin_ingest_as('test-fixture', 'stage', jsonb_build_object('upload_id', v_id, 'sheet', f->>'sheet', 'seq', 0, 'role', f->>'role',
                               'cols', case when f->>'role' = 'ledger' then lc else rcols end, 'rows', f->'rows'));
      c := bi.fin_ingest_as('test-fixture', 'commit', jsonb_build_object('upload_id', v_id, 'expected', jsonb_build_object(f->>'sheet', jsonb_array_length(f->'rows'))));
      rsp := rsp || jsonb_build_object(f->>'name', jsonb_build_object('id', v_id, 'commit', c));
    end loop;
    -- re-saved copy announced with the browser's content hash: refused at begin, nothing staged
    select controls->>'content_sha256' into h from bi.fin_upload where id = (rsp->'OS2C'->>'id')::bigint;
    select count(*) into n_after from bi.fin_upload;
    b := bi.fin_ingest_as('test-fixture', 'begin', jsonb_build_object('kind', 'outstanding', 'file_hash', encode(sha256(convert_to('fixture:DUPB', 'UTF8')), 'hex'),
                          'file_name', 'fixture_DUPB.xlsx', 'as_of', '2026-07-15', 'content_sha256', h));
    res := res || jsonb_build_object('t', 'F01 re-saved copy (same rows, new file) refused at begin by content hash; nothing staged',
                 'p', coalesce((b->>'duplicate_content')::boolean, false) and (b->>'upload_id')::bigint = (rsp->'OS2C'->>'id')::bigint and (select count(*) from bi.fin_upload) = n_after,
                 'd', b::text);
    res := res || jsonb_build_object('t', 'F02 re-saved copy without a browser hash: rejected at commit by the server hash',
                 'p', rsp->'DUPC'->'commit'->>'status' = 'rejected' and (rsp->'DUPC'->'commit'->>'same_as')::bigint = (rsp->'OS2C'->>'id')::bigint,
                 'd', (rsp->'DUPC'->'commit')::text);

    d := bi.fin_derive('test-fixture');

    res := res || jsonb_build_object('t', 'F03 corrected snapshot for the same date replaces the earlier one; a different date is kept, never added',
                 'p', (select status from bi.fin_upload where id = (rsp->'OS2'->>'id')::bigint) = 'superseded'
                      and (select status from bi.fin_upload where id = (rsp->'OS1'->>'id')::bigint) = 'committed'
                      and (d->>'outstanding_upload')::bigint = (rsp->'OS2C'->>'id')::bigint,
                 'd', format('OS1 %s, OS2 %s, OS2C current=%s', (select status from bi.fin_upload where id = (rsp->'OS1'->>'id')::bigint),
                             (select status from bi.fin_upload where id = (rsp->'OS2'->>'id')::bigint), d->>'outstanding_upload'));
    res := res || jsonb_build_object('t', 'F04 outstanding = latest snapshot only (36,400), earlier snapshots contribute 0',
                 'p', (select sum(os) from bi.fin_os_agg) = 36400 and (select coalesce(sum(os), 0) from bi.fin_os_agg where upload_id in ((rsp->'OS1'->>'id')::bigint, (rsp->'OS2'->>'id')::bigint)) = 0,
                 'd', (select sum(os) from bi.fin_os_agg)::text);
    res := res || jsonb_build_object('t', 'F05 invoice repeated inside one snapshot: flagged, counted once in invoice totals',
                 'p', (select dup_n from bi.fin_os_agg where upload_id = (rsp->'OS2C'->>'id')::bigint and inv_month = '2026-06-01') = 2
                      and exists (select 1 from bi.fin_review where kind = 'duplicate_line' and key like '%ZZT-2606-003%' and status = 'open')
                      and (select basic from bi.fin_inv_month where inv_month = '2026-06-01' and family = 'ZZTEST') = 5000,
                 'd', (select format('dup_n %s; invoice basic %s; invoices %s', o.dup_n, i.basic, i.inv_n) from bi.fin_os_agg o join bi.fin_inv_month i on i.inv_month = o.inv_month and i.family = o.family
                       where o.upload_id = (rsp->'OS2C'->>'id')::bigint and o.inv_month = '2026-06-01'));
    res := res || jsonb_build_object('t', 'F06 cumulative receipt workbook: the later file replaces the earlier one for the year; receipts counted once',
                 'p', (select status from bi.fin_upload where id = (rsp->'C1'->>'id')::bigint) = 'superseded' and (select sum(amount) from bi.fin_rcpt_agg) = 69100,
                 'd', format('C1 %s; cash total %s', (select status from bi.fin_upload where id = (rsp->'C1'->>'id')::bigint), (select sum(amount) from bi.fin_rcpt_agg)));
    res := res || jsonb_build_object('t', 'F07 receipt repeated in two current uploads (overlapping years) counted once',
                 'p', (d->>'receipts_repeated_across_uploads')::int = 1, 'd', 'repeated across uploads: ' || (d->>'receipts_repeated_across_uploads'));
    res := res || jsonb_build_object('t', 'F08 two identical credits inside one file: kept and sent to review as a possible double entry',
                 'p', exists (select 1 from bi.fin_review where kind = 'receipt_duplicate' and n = 2 and amount = 2900 and status = 'open'),
                 'd', coalesce((select title from bi.fin_review where kind = 'receipt_duplicate' and status = 'open' and amount = 2900 limit 1), 'missing'));
    res := res || jsonb_build_object('t', 'F09 unallocated receipt (no invoice, no location) kept apart from invoice-matched cash',
                 'p', (select sum(amount) - sum(inv_amount) from bi.fin_rcpt_agg) = 5000 and (select sum(amount) from bi.fin_rcpt_agg where location_id = 0) = 5000,
                 'd', format('unallocated %s', (select sum(amount) - sum(inv_amount) from bi.fin_rcpt_agg)));
    res := res || jsonb_build_object('t', 'F10 billed in May, paid in June/July: cash sits in the receipt months, revenue stays in May',
                 'p', (select basic from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST') = 45000
                      and (select coalesce(sum(amount), 0) from bi.fin_rcpt_agg where rcpt_month = '2026-05-01') = 0
                      and (select sum(amount) from bi.fin_rcpt_agg where rcpt_month = '2026-06-01') = 50100
                      and (select sum(amount) from bi.fin_rcpt_agg where rcpt_month = '2026-07-01') = 13200
                      and (select collected from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST') = 52500,
                 'd', (select format('May invoices %s; cash May %s, Jun %s, Jul %s; cash allocated to May invoices %s', i.basic,
                         (select coalesce(sum(amount), 0) from bi.fin_rcpt_agg where rcpt_month = '2026-05-01'), (select sum(amount) from bi.fin_rcpt_agg where rcpt_month = '2026-06-01'),
                         (select sum(amount) from bi.fin_rcpt_agg where rcpt_month = '2026-07-01'), i.collected) from bi.fin_inv_month i where i.inv_month = '2026-05-01' and i.family = 'ZZTEST'));
    res := res || jsonb_build_object('t', 'F11 partial payment: open basic = basic × open share of net; realisation of May invoices = settled ÷ invoiced (ex-GST)',
                 'p', (select round(open_basic, 2) from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST') = 21379.31
                      and (select round(settled_basic / basic, 4) from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST') = 0.5249,
                 'd', (select format('open %s, settled %s, realisation %s', round(open_basic, 2), round(settled_basic, 2), round(settled_basic / basic, 4)) from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST'));
    res := res || jsonb_build_object('t', 'F12 GST and TDS held separately from basic; TDS is not cash',
                 'p', (select gross_l = 35400 and tds_l = 600 and net_l = 34800 from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST')
                      and (select sum(gross) = 47200 and sum(tds) = 800 from bi.fin_os_agg where upload_id = (rsp->'OS2C'->>'id')::bigint),
                 'd', (select format('May: gross %s, TDS %s, net %s (cash allocated %s)', gross_l, tds_l, net_l, collected) from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST'));
    res := res || jsonb_build_object('t', 'F13 invoice known only from a receipt: counted once with the receipt''s invoice basic, nothing open',
                 'p', (select in_ledger_n = 2 and receipt_only_n = 1 from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST'),
                 'd', (select format('in ledger %s, receipt only %s', in_ledger_n, receipt_only_n) from bi.fin_inv_month where inv_month = '2026-05-01' and family = 'ZZTEST'));
    res := res || jsonb_build_object('t', 'F14 receipt against an invoice the snapshot still shows fully unpaid goes to review',
                 'p', exists (select 1 from bi.fin_review where kind = 'receipt_still_open' and key = 'ZZT-2605-001' and amount = 11600 and status = 'open'),
                 'd', coalesce((select title from bi.fin_review where kind = 'receipt_still_open' and key = 'ZZT-2605-001'), 'missing'));
    raise exception using errcode = 'P0001', message = 'fixture rollback';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'fixture rollback' then raise; end if;
  end;
  select count(*), coalesce(sum(os), 0) into n_after, agg_after from bi.fin_os_agg;
  res := res || jsonb_build_object('t', 'F15 fixtures fully undone: live finance aggregates and uploads unchanged',
               'p', n_after = n_before and agg_after = agg_before and not exists (select 1 from bi.fin_upload where file_name like 'fixture\_%') and not exists (select 1 from bi.fin_loc_map where key = 'ZZT'),
               'd', format('rows %s → %s, open %s → %s', n_before, n_after, agg_before, agg_after));
  return query select e->>'t', (e->>'p')::boolean, e->>'d' from jsonb_array_elements(res) e;
end $$;
revoke all on function bi.test_fin_fixtures() from public, anon, authenticated;

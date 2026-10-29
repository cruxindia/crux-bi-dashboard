-- Applied to Supabase project via MCP on 20261029045655
-- bi_097c (29-Oct-2026)
-- (1) Case location: rules 2 and 4 (office learned for the branch, the branch customers' area) are learned from all cases of the same branches, not
--     only from the cases being placed, so an upload batch gets the same answer as a full run (the identity audit found 151 cases whose stored
--     location differed from a full run of the rules for this reason).
-- (2) Identity audit: finance lines with location 0 (not tied to a location) count as without location.
-- (3) Outstanding reconciliation traced further: invoice numbers used in two sheets (same lines vs different invoices sharing a number), duplicate-line
--     review items, sheets whose unadjusted receipts exceed their outstanding, explained vs unexplained difference and a plain status.
-- (4) Collection workbook check: bank sheets, months, Main cross-check, pivots, review items and the file's label vs its last receipt date.
do $do$
declare d text; fn text; i int;
  r text[][] := array[
    [$o$      from bi.case_store cs where p_cases is null or cs.case_id = any (p_cases)),$o$,
     $n$      from bi.case_store cs where p_cases is null or cs.case_id = any (p_cases)),
  -- bi_097c: rules 2 and 4 learn from all cases of the same branches (a batch gets the same answer as a full run)
  cb as materialized (
    select cs.case_id, cs.client_code, cs.branch_id, cs.area_office_id from bi.case_store cs
     where p_cases is null or cs.case_id = any (p_cases) or cs.branch_id in (select c.branch_id from c where c.branch_id is not null)),$n$],
    [$o$from (select distinct c.area_office_id, c.client_code from c where c.area_office_id is not null) k)$o$,
     $n$from (select distinct c.area_office_id, c.client_code from cb c where c.area_office_id is not null) k)$n$],
    [$o$      from bi.point_store p join c on c.case_id = p.case_id$o$, $n$      from bi.point_store p join cb c on c.case_id = p.case_id$n$],
    [$o$        from (select c.branch_id, aol.ao_raw from c join aol on$o$, $n$        from (select c.branch_id, aol.ao_raw from cb c join aol on$n$],
    [$o$        from c join pin on pin.case_id = c.case_id join pinp pp on pp.pin = pin.pin where c.branch_id is not null$o$,
     $n$        from cb c join pin on pin.case_id = c.case_id join pinp pp on pp.pin = pin.pin where c.branch_id is not null$n$]];
begin
  foreach fn in array array['bi.case_locate(bigint[])', 'bi.case_locate_detail(bigint[])'] loop
    d := pg_get_functiondef(fn::regprocedure);
    for i in 1 .. array_length(r, 1) loop
      if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception '% fragment % not found exactly once', fn, i; end if;
      d := replace(d, r[i][1], r[i][2]);
    end loop;
    execute d;
  end loop;
  d := pg_get_functiondef('bi.identity_audit_run(integer)'::regprocedure);
  r := array[[$o$'with_location', round(sum(amt) filter (where location_id is not null), 2),$o$, $n$'with_location', round(coalesce(sum(amt) filter (where location_id > 0), 0), 2),$n$],
             [$o$'without_location', round(coalesce(sum(amt) filter (where location_id is null), 0), 2),$o$, $n$'without_location', round(coalesce(sum(amt) filter (where coalesce(location_id, 0) = 0), 0), 2),$n$],
             [$o$'location_share', round(sum(amt) filter (where location_id is not null) / nullif(sum(amt), 0), 4),$o$, $n$'location_share', round(coalesce(sum(amt) filter (where location_id > 0), 0) / nullif(sum(amt), 0), 4),$n$]];
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'identity_audit_run fragment % not found', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
end $do$;

create or replace function bi.api_os_recon() returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare u bi.fin_upload; sh jsonb; r jsonb; xs jsonb; dup jsonb;
begin
  select * into u from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  if u.id is null then return jsonb_build_object('available', false); end if;
  sh := coalesce(u.controls->'sheets', '{}'::jsonb);
  -- invoice numbers that appear in more than one sheet: the same lines (counted twice in the workbook total) or different invoices sharing a number
  with l as materialized (select sheet, upper(btrim(inv)) iv, upper(btrim(coalesce(cl, ''))) cl, upper(btrim(coalesce(br, ''))) br, im, round(basic, 2) basic, round(os, 2) os
                            from bi.fin_os_lines(u.id) where coalesce(btrim(inv), '') <> ''),
       k as (select iv from l group by 1 having count(distinct sheet) > 1),
       ps as (select l.iv, l.sheet, array_agg(l.cl || '|' || l.br || '|' || coalesce(l.im::text, '') || '|' || l.basic || '|' || l.os order by l.cl, l.br, l.im, l.basic, l.os) sig, sum(l.os) os
                from l join k using (iv) group by 1, 2),
       pi as (select iv, count(distinct sig) nsig, sum(os) os, max(os) one, string_agg(sheet, ' + ' order by sheet) pair from ps group by 1)
  select jsonb_build_object('numbers', count(*), 'same_lines', count(*) filter (where nsig = 1),
           'same_lines_counted_twice', round(coalesce(sum(os - one) filter (where nsig = 1), 0), 2),
           'different_invoices_sharing_a_number', count(*) filter (where nsig > 1),
           'by_sheet_pair', (select coalesce(jsonb_agg(jsonb_build_object('sheets', pair, 'numbers', c, 'same_lines', s1) order by c desc), '[]') from (select pair, count(*) c, count(*) filter (where nsig = 1) s1 from pi group by 1) z),
           'examples', (select coalesce(jsonb_agg(jsonb_build_object('invoice', iv, 'sheets', pair, 'same_lines', nsig = 1) order by nsig, iv), '[]') from (select * from pi order by nsig, iv limit 12) e),
           'note', 'Lines are compared on client, branch, invoice month, basic and outstanding; applicant names are never stored, so two lines that differ only in the applicant count as the same here.')
    into xs from pi;
  dup := (select jsonb_build_object('open_groups', count(*), 'amount', round(coalesce(sum(amount), 0), 2)) from bi.fin_review where kind = 'duplicate_line' and status = 'open' and upload_id = u.id);
  with s as (select key sheet, (value->>'os')::numeric os, (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(coalesce(value->'unadj', '[]')) x) un,
                    (value->>'rows')::int n, value->'sheet_total' st
               from jsonb_each(sh) where value->>'role' = 'ledger'),
       sm as (select x->>'label' label, (x->>'total')::numeric total, (x->>'unadj')::numeric unadj, (x->>'net')::numeric net, x->>'remark' remark, o.i
                from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z
                cross join lateral jsonb_array_elements(coalesce(z.value->'summary', '[]')) with ordinality o(x, i) where coalesce(x->>'label', '') <> 'Total'),
       mt as (select sm.*, (select s.sheet from s where sm.total is not null and abs(s.os - sm.total) < 1 order by abs(s.os - sm.total) limit 1) sheet from sm),
       rows_ as (
         select mt.label summary_row, mt.sheet, mt.total summary_total, s.os sheet_total, coalesce(s.os, 0) - coalesce(mt.total, 0) diff_total,
                mt.unadj summary_unadj, s.un sheet_unadj, coalesce(s.un, 0) - coalesce(mt.unadj, 0) diff_unadj, mt.i ord, mt.remark,
                case when mt.total is null then 'in the summary without an amount' when s.sheet is null then 'no matching location sheet' else 'matches' end status
           from mt left join s on s.sheet = mt.sheet
         union all
         select null, s.sheet, null, s.os, s.os, null, s.un, s.un, 1000, null, 'location sheet missing from the summary'
           from s where not exists (select 1 from mt where mt.sheet = s.sheet)),
       tot as (select (x->>'total')::numeric gross, (x->>'unadj')::numeric unadj, (x->>'net')::numeric net
                 from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z cross join lateral jsonb_array_elements(z.value->'summary') x where x->>'label' = 'Total' limit 1),
       ex as (select coalesce(sum(sheet_total) filter (where status = 'location sheet missing from the summary'), 0) explained,
                     (select sum(os) from s) - coalesce((select gross from tot), 0) diff from rows_)
  select jsonb_build_object('available', true, 'upload_id', u.id, 'file_name', u.file_name, 'as_of', u.as_of, 'as_of_basis', u.as_of_basis,
    'gross', (select round(sum(os), 2) from s), 'unadjusted', (select round(sum(un), 2) from s), 'net', (select round(sum(os) - sum(un), 2) from s),
    'lines', (select sum(n) from s),
    'line_measures', (select jsonb_build_object('basic', round(sum((st->>'basic')::numeric), 2), 'gross_incl_gst', round(sum((st->>'gross')::numeric), 2), 'tds', round(sum((st->>'tds')::numeric), 2),
                        'net_after_tds', round(sum((st->>'net')::numeric), 2), 'partial_received', round(sum((st->>'partial')::numeric), 2), 'sheets_with_totals', count(st)) from s where st is not null and jsonb_typeof(st) = 'object'),
    'summary', (select jsonb_build_object('gross', gross, 'unadjusted', unadj, 'net', net) from tot),
    'adjustments', (select coalesce(jsonb_agg(a order by o.i), '[]') from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z cross join lateral jsonb_array_elements(coalesce(z.value->'adjustments', '[]')) with ordinality o(a, i)),
    'rows', (select coalesce(jsonb_agg(to_jsonb(rows_) - 'ord' order by ord, sheet), '[]') from rows_),
    'reconciled', not exists (select 1 from rows_ where status <> 'matches' or abs(diff_total) >= 1),
    'explained', (select round(explained, 2) from ex), 'unexplained', (select round(diff - explained, 2) from ex),
    'status', (select case when not exists (select 1 from rows_ where status <> 'matches' or abs(diff_total) >= 1) then 'Reconciled'
                           when abs(diff - explained) < 1 then 'Not reconciled — difference explained (the summary sheet leaves out location sheets)'
                           else 'Unreconciled — ' || bi.fmt_inr(round(diff - explained, 2)) || ' not explained' end from ex),
    'sheet_checks', (select coalesce(jsonb_agg(jsonb_build_object('sheet', sheet, 'outstanding', round(os, 2), 'unadjusted', round(un, 2), 'net', round(os - un, 2),
                        'issue', 'received but not linked exceeds the outstanding — net is negative') order by sheet), '[]') from s where un > os),
    'cross_sheet_invoices', xs, 'duplicate_lines', dup,
    'definitions', jsonb_build_object('gross', 'Workbook "Total Outstanding" = Σ "Actual Outstanding" per line = invoice net (basic + GST − TDS) less partial receipts.',
                    'unadjusted', 'Money received but not yet linked to an invoice ("Less Unadj" lines under each sheet).',
                    'net', 'Gross − unadjusted. The workbook''s further adjustments are listed and never deducted until approved.'),
    'method', 'Gross = the location sheets'' outstanding (the managers'' collection and reconciliation target). Unadjusted = receipts already in the bank but not yet linked to an invoice (each sheet''s "Less Unadj" lines). Net = gross − unadjusted = invoice balance still to collect. The workbook''s further adjustments are listed but not deducted until approved. The summary sheet is compared with the location sheets row by row; a difference counts as explained only when a whole location sheet is missing from the summary.')
    into r;
  return r;
end $f$;

create or replace function bi.api_coll_recon() returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare u bi.fin_upload; sh jsonb; r jsonb;
begin
  select * into u from bi.fin_upload where kind = 'collection' and status = 'committed' order by as_of desc, id desc limit 1;
  if u.id is null then return jsonb_build_object('available', false); end if;
  sh := coalesce(u.controls->'sheets', '{}'::jsonb);
  select jsonb_build_object('available', true, 'upload_id', u.id, 'file_name', u.file_name, 'last_receipt', u.as_of, 'as_of_basis', u.as_of_basis, 'first_receipt_month', u.period_from,
    'file_label', (regexp_match(u.file_name, '(?i)(?:till|upto|up to)\s+([A-Za-z]{3,9}\s*''?\d{2,4})'))[1],
    'bank_sheets', (select coalesce(jsonb_agg(jsonb_build_object('sheet', key, 'rows', (value->>'rows')::int, 'credit', (value->>'credit')::numeric, 'first', value->>'min_date', 'last', value->>'max_date',
                      'with_invoice', (value->>'with_invoice')::int, 'invoice_credit', (value->>'invoice_credit')::numeric, 'multi_invoice', (value->>'multi_invoice')::int,
                      'month_label_differs', (value->>'ym_number_vs_column_differ')::int) order by key), '[]') from jsonb_each(sh) where value->>'role' = 'bank'),
    'bank_rows', (select sum((value->>'rows')::int) from jsonb_each(sh) where value->>'role' = 'bank'),
    'bank_credit', (select round(sum((value->>'credit')::numeric), 2) from jsonb_each(sh) where value->>'role' = 'bank'),
    'by_month', (select coalesce(jsonb_object_agg(m, v), '{}') from (select b.k m, round(sum(b.v::numeric), 2) v from jsonb_each(sh) e cross join lateral jsonb_each_text(e.value->'by_month') b(k, v) where e.value->>'role' = 'bank' group by 1) z),
    'main', (select jsonb_build_object('rows', (value->>'rows')::int, 'credit', (value->>'credit')::numeric, 'by_month', value->'by_month', 'vs_bank_sheets', value->'vs_bank_sheets')
               from jsonb_each(sh) where value->>'role' = 'main' limit 1),
    'pivots', (select coalesce(jsonb_object_agg(key, (value->>'grand_total')::numeric), '{}') from jsonb_each(sh) where value->>'role' = 'summary'),
    'review', (select coalesce(jsonb_object_agg(kind, jsonb_build_object('open', n, 'amount', a)), '{}') from (select kind, count(*) n, round(coalesce(sum(amount), 0), 2) a from bi.fin_review
                 where status = 'open' and upload_id = u.id and kind in ('receipt_duplicate', 'multi_invoice_ref', 'odd_invoice_ref', 'receipt_still_open') group by 1) z),
    'repeated_across_uploads', (select (summary->>'receipts_repeated_across_uploads')::int from bi.fin_run order by id desc limit 1),
    'not_tied_by_month', (select coalesce(jsonb_object_agg(to_char(m, 'YYYY-MM'), jsonb_build_object('amount', a, 'share', s)), '{}') from (
                           select m, round(sum(amt) filter (where coalesce(location_id, 0) = 0), 2) a, round(sum(amt) filter (where coalesce(location_id, 0) = 0) / nullif(sum(amt), 0), 4) s
                             from bi.fin_attr where kind = 'collected' group by m) z),
    'issues', coalesce(u.controls->'issues', '[]'::jsonb),
    'method', 'The bank-account sheets are the receipt ledger (one row per bank credit). "Main" covers only some months and is used as a cross-check, never added; the pivot sheets are workbook summaries of Main and are compared, never added. A receipt counts in its receipt month, never as revenue billed in that month. Identical credits (same sheet, date, amount, narration and allocated invoice) are kept and sent to review as possible double entries; nothing is removed automatically. Re-importing the same rows changes nothing; a later cumulative file replaces the earlier one.')
    into r;
  return r;
end $f$;

do $do$
declare d text; o text := $o$      when 'os_recon' then bi.api_os_recon()$o$;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_call fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$      when 'coll_recon' then bi.api_coll_recon()$n$);
end $do$;

-- Applied to Supabase project via MCP on 20261028134534
-- bi_096c (28-Oct-2026): outstanding as three separate measures + workbook reconciliation, from the latest outstanding workbook's own controls.
-- gross = collection + reconciliation target (location sheets); unadjusted = money received but not linked to an invoice yet; net = gross − unadjusted.
-- Workbook adjustments ("Less - Unadj Branch", "Less - Sep 26 Billing", "Actual Outstanding") are listed, never deducted.
create or replace function bi.api_os_recon() returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare u bi.fin_upload; sh jsonb; r jsonb;
begin
  select * into u from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  if u.id is null then return jsonb_build_object('available', false); end if;
  sh := coalesce(u.controls->'sheets', '{}'::jsonb);
  with s as (select key sheet, (value->>'os')::numeric os, (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(coalesce(value->'unadj', '[]')) x) un,
                    (value->>'rows')::int n
               from jsonb_each(sh) where value->>'role' = 'ledger'),
       sm as (select x->>'label' label, (x->>'total')::numeric total, (x->>'unadj')::numeric unadj, (x->>'net')::numeric net, o.i
                from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z
                cross join lateral jsonb_array_elements(coalesce(z.value->'summary', '[]')) with ordinality o(x, i) where coalesce(x->>'label', '') <> 'Total'),
       mt as (select sm.*, (select s.sheet from s where sm.total is not null and abs(s.os - sm.total) < 1 order by abs(s.os - sm.total) limit 1) sheet from sm),
       rows_ as (
         select mt.label summary_row, mt.sheet, mt.total summary_total, s.os sheet_total, coalesce(s.os, 0) - coalesce(mt.total, 0) diff_total,
                mt.unadj summary_unadj, s.un sheet_unadj, coalesce(s.un, 0) - coalesce(mt.unadj, 0) diff_unadj, mt.i ord,
                case when mt.total is null then 'in the summary without an amount' when s.sheet is null then 'no matching location sheet' else 'matches' end status
           from mt left join s on s.sheet = mt.sheet
         union all
         select null, s.sheet, null, s.os, s.os, null, s.un, s.un, 1000, 'location sheet missing from the summary'
           from s where not exists (select 1 from mt where mt.sheet = s.sheet))
  select jsonb_build_object('available', true, 'upload_id', u.id, 'file_name', u.file_name, 'as_of', u.as_of, 'as_of_basis', u.as_of_basis,
    'gross', (select round(sum(os), 2) from s), 'unadjusted', (select round(sum(un), 2) from s), 'net', (select round(sum(os) - sum(un), 2) from s),
    'lines', (select sum(n) from s),
    'summary', jsonb_build_object('gross', (select x->>'total' from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z cross join lateral jsonb_array_elements(z.value->'summary') x where x->>'label' = 'Total' limit 1)::numeric,
                                  'unadjusted', (select x->>'unadj' from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z cross join lateral jsonb_array_elements(z.value->'summary') x where x->>'label' = 'Total' limit 1)::numeric,
                                  'net', (select x->>'net' from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z cross join lateral jsonb_array_elements(z.value->'summary') x where x->>'label' = 'Total' limit 1)::numeric),
    'adjustments', (select coalesce(jsonb_agg(a order by o.i), '[]') from (select key, value from jsonb_each(sh) where value->>'role' = 'summary') z cross join lateral jsonb_array_elements(coalesce(z.value->'adjustments', '[]')) with ordinality o(a, i)),
    'rows', (select coalesce(jsonb_agg(to_jsonb(rows_) - 'ord' order by ord, sheet), '[]') from rows_),
    'reconciled', not exists (select 1 from rows_ where status <> 'matches' or abs(diff_total) >= 1),
    'method', 'Gross = the location sheets'' outstanding (the managers'' collection and reconciliation target). Unadjusted = receipts already in the bank but not yet linked to an invoice (each sheet''s "Less Unadj" lines). Net = gross − unadjusted = invoice balance still to collect. The workbook''s further adjustments are listed but not deducted until approved. The summary sheet is compared with the location sheets row by row.')
    into r;
  return r;
end $f$;

do $do$
declare d text; o text := $o$      when 'bm' then bi.api_bm(m, f, coalesce(p_args->'p', '{}'::jsonb))$o$;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_call fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$      when 'os_recon' then bi.api_os_recon()$n$);
end $do$;

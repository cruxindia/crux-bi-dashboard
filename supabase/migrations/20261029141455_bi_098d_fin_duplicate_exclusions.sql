-- Applied to Supabase project via MCP on 20261029141455
-- Wave 098 (owner decision 29-Oct-2026 19:35 IST, "if duplicate remove"): a finance line that repeats another line of the same sheet in EVERY stored
-- field (invoice, client, month, basic, GST, TDS, net, partial, outstanding, remark for outstanding; date, amount, narration hash, invoice, payer for receipts)
-- is excluded from the figures. The source row stays in bi.fin_part (history kept); the exclusion is listed with its reason and approver.
-- Lines that only look alike (same invoice and amount but another field differs) stay in Finance review.
create table if not exists bi.fin_line_exclusion (
  upload_id bigint not null,
  sheet text not null,
  r integer not null,
  kind text not null check (kind in ('outstanding', 'collection')),
  keep_r integer not null,
  amount numeric,
  reason text not null,
  approved_by text not null,
  approved_at timestamptz not null default now(),
  primary key (upload_id, sheet, r)
);
alter table bi.fin_line_exclusion enable row level security;
comment on table bi.fin_line_exclusion is 'Wave 098: finance source rows excluded from figures as exact duplicates of keep_r (owner decision 29-Oct-2026); rows remain in fin_part.';

do $mig$
declare d text; a text; b text;
begin
  d := pg_get_functiondef('bi.fin_os_lines(bigint)'::regprocedure);
  a := 'where p.upload_id = p_upload and p.role = ''ledger''),';
  b := 'where p.upload_id = p_upload and p.role = ''ledger''
      and not exists (select 1 from bi.fin_line_exclusion z where z.upload_id = p.upload_id and z.sheet = p.sheet and z.r = (x->>0)::int)),';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'fin_os_lines fragment not found exactly once'; end if;
  execute replace(d, a, b);

  d := pg_get_functiondef('bi.fin_receipts(bigint)'::regprocedure);
  a := 'where p.upload_id = p_upload and p.role in (''bank'', ''main'')),';
  b := 'where p.upload_id = p_upload and p.role in (''bank'', ''main'')
      and not exists (select 1 from bi.fin_line_exclusion z where z.upload_id = p.upload_id and z.sheet = p.sheet and z.r = (x->>0)::int)),';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'fin_receipts fragment not found exactly once'; end if;
  execute replace(d, a, b);

  d := pg_get_functiondef('bi.api_os_recon()'::regprocedure);
  a := '    into r;
  return r;';
  b := '    into r;
  -- wave 098: exact duplicate lines excluded under the owner decision; the workbook comparison above stays on the figures as recorded
  r := r || (select jsonb_build_object(''gross_as_recorded'', r->''gross'', ''net_as_recorded'', r->''net'',
              ''gross'', round((r->>''gross'')::numeric - coalesce(sum(e.amount), 0), 2), ''net'', round((r->>''net'')::numeric - coalesce(sum(e.amount), 0), 2),
              ''excluded_duplicates'', jsonb_build_object(''lines'', count(e.*), ''amount'', round(coalesce(sum(e.amount), 0), 2),
                 ''note'', ''Lines identical to another line of the same sheet in every stored field, excluded under the owner decision of 29-Oct-2026; the source rows are kept.''))
             from bi.fin_line_exclusion e where e.upload_id = u.id and e.kind = ''outstanding'');
  return r;';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_os_recon fragment not found exactly once'; end if;
  execute replace(d, a, b);

  d := pg_get_functiondef('bi.api_coll_recon()'::regprocedure);
  a := 'Identical credits (same sheet, date, amount, narration and allocated invoice) are kept and sent to review as possible double entries; nothing is removed automatically.';
  b := 'Credits identical in every stored field (same sheet, date, amount, narration, invoice and payer) are excluded as double entries under the owner decision of 29-Oct-2026 and listed here (the source rows are kept); credits that only look alike stay in review.';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_coll_recon method fragment not found exactly once'; end if;
  d := replace(d, a, b);
  a := '    into r;
  return r;';
  b := '    into r;
  r := r || (select jsonb_build_object(''excluded_duplicates'', jsonb_build_object(''rows'', count(e.*), ''amount'', round(coalesce(sum(e.amount), 0), 2)),
              ''bank_credit_after_exclusions'', round((r->>''bank_credit'')::numeric - coalesce(sum(e.amount), 0), 2))
             from bi.fin_line_exclusion e where e.upload_id = u.id and e.kind = ''collection'');
  return r;';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'api_coll_recon fragment not found exactly once'; end if;
  execute replace(d, a, b);
end $mig$;

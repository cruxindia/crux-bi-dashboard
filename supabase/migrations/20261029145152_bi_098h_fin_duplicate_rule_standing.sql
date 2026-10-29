-- Applied to Supabase project via MCP on 20261029145152
-- Wave 098: the owner's duplicate decision (29-Oct-2026) is a standing rule, applied to every committed finance upload before the figures are derived,
-- so a re-sent or newer workbook does not bring the same duplicates back.
--   receipts (bank sheets): a row identical to an earlier row of the same sheet in every stored field
--   outstanding (location sheets): a row with an invoice number that repeats an earlier row of the same sheet in invoice (ignoring spaces / case),
--   client, location, month and every amount (remark ignored); rows without an invoice only when identical in every stored field
create or replace function bi.fin_apply_duplicate_rule(p_actor text default 'standing rule')
returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare n_os int; n_rc int;
begin
  with u as (select id, kind from bi.fin_upload where status in ('committed', 'superseded') and kind in ('outstanding', 'collection')),
  rows_ as (select p.upload_id, u.kind, p.sheet, (x->>0)::int r,
                   case when u.kind = 'outstanding' and nullif(btrim(x->>6), '') is not null then
                          concat_ws('|', lower(btrim(x->>1)), x->>2, lower(btrim(x->>4)), regexp_replace(upper(x->>6), '[^A-Z0-9]', '', 'g'),
                                    x->>7, x->>8, x->>9, x->>10, x->>11, x->>12)
                        else (x - 0)::text end sig,
                   case when u.kind = 'outstanding' then (x->>12)::numeric else (x->>5)::numeric end amt,
                   case when u.kind = 'outstanding' and nullif(btrim(x->>6), '') is not null then 'duplicate of row %s: same invoice, client, location, month and all amounts (formatting or remark may differ)'
                        else 'exact duplicate of row %s (every stored field identical)' end why
              from bi.fin_part p join u on u.id = p.upload_id cross join lateral jsonb_array_elements(p.rows) x
             where (u.kind = 'outstanding' and p.role = 'ledger') or (u.kind = 'collection' and p.role = 'bank')),
  k as (select rows_.*, min(r) over (partition by upload_id, sheet, sig) keep_r from rows_),
  ins as (insert into bi.fin_line_exclusion(upload_id, sheet, r, kind, keep_r, amount, reason, approved_by)
          select upload_id, sheet, r, kind, keep_r, amt, format(why, keep_r), 'owner decision 29-Oct-2026 ("if duplicate remove") — ' || p_actor
            from k where r <> keep_r
          on conflict do nothing returning kind)
  select count(*) filter (where kind = 'outstanding'), count(*) filter (where kind = 'collection') into n_os, n_rc from ins;
  if n_os + n_rc > 0 then
    insert into bi.audit_log(actor, action, entity, entity_key, detail)
    values (p_actor, 'fin_duplicates_excluded', 'fin_line_exclusion', 'standing rule', jsonb_build_object('outstanding_rows', n_os, 'receipt_rows', n_rc));
  end if;
  return jsonb_build_object('outstanding_rows', n_os, 'receipt_rows', n_rc);
end $f$;
comment on function bi.fin_apply_duplicate_rule(text) is 'Wave 098: applies the owner''s duplicate rule (29-Oct-2026) to every committed finance upload; idempotent.';

-- run it at the start of every derive (new uploads are covered before their figures are built)
do $mig$
declare d text := pg_get_functiondef('bi.fin_derive(text)'::regprocedure); a text; b text;
begin
  a := substring(d from '(\nbegin\n)');
  if a is null or (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'fin_derive begin not found exactly once'; end if;
  b := a || '  perform bi.fin_apply_duplicate_rule(''derive: '' || coalesce(p_actor, ''unknown''));' || chr(10);
  execute replace(d, a, b);
end $mig$;

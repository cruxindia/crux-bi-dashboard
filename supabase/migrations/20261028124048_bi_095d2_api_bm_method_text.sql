-- Applied to Supabase project via MCP on 20261028124048
do $do$
declare d text; a int; b int;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  a := position('Zone-billed invoices, receipts and outstanding are allocated' in d);
  b := position('when they have different managers.' in d);
  if a = 0 or b < a then raise exception 'method text not found'; end if;
  b := b + length('when they have different managers.');
  execute substr(d, 1, a - 1) || 'Each invoice, receipt and outstanding line counts whole for one location × client — never shared out: location from the invoice series, the row label, a place named in the client or branch text, or the paying bank branch (branch code → client branch master); client from the client text, else the family''''s main client there. A zone-level line (location not identified) counts for a manager only when that zone has one manager for the client; otherwise it is shown as not attributable.' || substr(d, b);
end $do$;

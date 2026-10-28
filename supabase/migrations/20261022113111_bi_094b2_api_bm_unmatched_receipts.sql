-- Applied to Supabase project via MCP on 20261022113111
-- bi_094b2 (22-Oct-2026): receipts not yet matched to an invoice have no client family ("(none)"); when their location is known they are
-- allocated across that location's clients (by tracker expected revenue) instead of being left unattributed. Location-less receipts stay unattributed.
do $do$
declare d text; o text := $o$      join cl on cl.code = h.client_code and cl.fam = s.family$o$;
        n text := $n$      join cl on cl.code = h.client_code and (cl.fam = s.family or s.family = '(none)')$n$;
begin
  d := pg_get_functiondef('bi.api_bm(date,jsonb,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'api_bm fragment not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;

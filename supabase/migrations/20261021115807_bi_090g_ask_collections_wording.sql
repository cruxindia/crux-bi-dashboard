-- Applied to Supabase project via MCP on 20261021115807
-- bi_090g (21-Oct-2026): clearer collections answers (no repeated headline, month names kept) and per-case / billing questions routed to the collections handler
do $do$
declare d text := pg_get_functiondef('bi.ask_h_collections(date,jsonb,text)'::regprocedure); a int; b int; frag text;
  fr text[] := array[
    $x$last jsonb; prev jsonb; part jsonb; i int := 0; r record; lim text;$x$,
    $x$bi.fmt_inr((part->>'collected')::numeric)) else '' end || ans;$x$,
    $x$format('%s is on invoices raised before April 2024. ', bi.fmt_inr((k->>'pre_apr_2024')::numeric)) else '' end || ans;$x$];
  tob text[] := array[
    $x$last jsonb; prev jsonb; part jsonb; i int := 0; r record; lim text; h_os text; h_col text; h_real text;$x$,
    $x$bi.fmt_inr((part->>'collected')::numeric)) else '' end || h_os;$x$,
    $x$format('%s is on invoices raised before April 2024. ', bi.fmt_inr((k->>'pre_apr_2024')::numeric)) else '' end || 'The locations below hold the most over 180 days.' || h_real;$x$];
  i int;
begin
  if position('h_real' in d) > 0 then return; end if;
  for i in 1 .. array_length(fr, 1) loop
    if (length(d) - length(replace(d, fr[i], ''))) / length(fr[i]) <> 1 then raise exception 'fragment % not found once', i; end if;
    d := replace(d, fr[i], tob[i]);
  end loop;
  a := position($x$  ans := format('Outstanding %s as at %s$x$ in d);
  b := position($x$  if focus = 'trend' then$x$ in d);
  if a = 0 or b = 0 or b < a then raise exception 'headline block not found'; end if;
  frag := substring(d from a for b - a);
  d := replace(d, frag, $x$  h_os := format('Outstanding %s as at %s (%s); %s (%s) is over 180 days.',
    bi.fmt_inr((k->>'outstanding')::numeric), to_char((sn->>'as_of')::date, 'DD-Mon-YYYY'),
    case when k->>'net_receivable' is null then 'net receivable is not available with a client filter' else 'net of unadjusted receipts ' || bi.fmt_inr((k->>'net_receivable')::numeric) end,
    bi.fmt_inr((k->>'over_180')::numeric), bi.fmt_p((k->>'over_180_share')::numeric));
  h_col := format(' Collected %s in %s%s.', bi.fmt_inr((k->>'collected_last_month')::numeric), to_char((rc->>'last_complete_month')::date, 'Mon YYYY'),
    case when prev is not null then format(' vs %s in %s', bi.fmt_inr((prev->>'collected')::numeric), to_char((prev->>'month')::date, 'Mon')) else '' end);
  h_real := format(' Realisation %s on invoices raised %s–%s; cash received was %s of reported revenue over %s.',
    bi.fmt_p((k->>'realisation')::numeric), to_char((a->'flow'->0->>'month')::date, 'Mon'), to_char(date_trunc('month', (sn->>'as_of')::date) - interval '2 month', 'Mon YYYY'),
    bi.fmt_p((k->>'cash_cover_3m')::numeric),
    (select to_char((a->'comparison_months'->>0)::date, 'Mon') || '–' || to_char((a->'comparison_months'->>(jsonb_array_length(a->'comparison_months') - 1))::date, 'Mon YYYY')));
  ans := h_os || h_col || h_real;

$x$);
  execute d;
end $do$;

do $do$
declare d text := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure); o text := $x$|debtor|billing|billed|cash)' then 'collections'$x$;
begin
  if position('per case|billing gap' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'collections intent pattern not found once'; end if;
  execute replace(d, o, $x$|debtor|billing|billed|cash|per case|billing gap|unbilled)' then 'collections'$x$);
end $do$;

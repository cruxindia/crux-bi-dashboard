-- Applied to Supabase project via MCP on 20261022042602
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.api_collections(date,jsonb)'::regprocedure);
  o := array[$o0$  with iv as (select i.inv_month mo, sum(i.basic) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n$o0$,
$o1$            'invoices', iv.n, 'age_days', v_asof - (g.mo + interval '1 month' - interval '1 day')::date) order by g.mo), '[]'),$o1$,
$o2$  v_realb numeric; v_reals numeric; v_moout numeric; v_x jsonb;$o2$,
$o3$  return jsonb_build_object('available', true,$o3$,
$o4$       'cash_cover', 'Cash received ÷ reported revenue for the same complete months. Receipts include GST and are after TDS; revenue excludes GST.',$o4$];
  n := array[$n0$  with iv as (select i.inv_month mo, sum(i.basic) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n, sum(i.collected) col, sum(i.gross_l) gl, sum(i.tds_l) tl$n0$,
$n1$            'invoices', iv.n, 'age_days', v_asof - (g.mo + interval '1 month' - interval '1 day')::date,
            'expected', round(rv.rev), 'cash_allocated', round(iv.col), 'gross_in_ledger', round(iv.gl), 'tds_in_ledger', round(iv.tl),
            'billing_status', bi.fin_month_status(g.mo, v_bb)) order by g.mo), '[]'),$n1$,
$n2$  v_realb numeric; v_reals numeric; v_moout numeric; v_x jsonb; v_bb jsonb := bi.fin_billing_basis();$n2$,
$n3$  return jsonb_build_object('available', true, 'billing', v_bb,$n3$,
$n4$       'cash_cover', 'Cash received ÷ expected minimum revenue (Zonal Tracker) for the same complete months. Receipts include GST and are after TDS while expected revenue excludes GST, so this is a cash-flow indicator, not a collection rate. The like-for-like collection measure is realisation (ex-GST, by invoice month).',$n4$];
  for i in 1 .. array_length(o, 1) loop
    if position(o[i] in d) = 0 then raise exception 'api_collections fragment % not found', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;


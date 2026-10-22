-- Applied to Supabase project via MCP on 20261022042216
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.fin_derive(text)'::regprocedure);
  o := array[$o0$  rc as materialized (select u.id upload_id, x.* from unnest(v_co) u(id) cross join lateral bi.fin_receipts(u.id) x where x.role = 'bank'),
  m as materialized ($o0$,
$o1$    insert into bi.fin_os_agg as t (upload_id, location_id, family, inv_month, n, basic, net, partial, os, os_basic, neg_n, neg_os, dup_n, dup_os, run_id)
    select v_os, l.location_id, l.family, coalesce(l.im, date '1900-01-01'), count(*), coalesce(sum(l.basic), 0), coalesce(sum(l.net), 0), sum(l.partial), sum(l.os),$o1$,
$o2$           count(*) filter (where dk.c > 1), coalesce(sum(l.os * (dk.c - 1)::numeric / dk.c) filter (where dk.c > 1), 0), v_run
    from l left join dk$o2$,
$o3$      os = excluded.os, os_basic = excluded.os_basic, neg_n = excluded.neg_n, neg_os = excluded.neg_os, dup_n = excluded.dup_n, dup_os = excluded.dup_os, run_id = v_run$o3$,
$o4$  ou as (select inv_key, basic, net, os, min(im) im, max(location_id) loc, min(family) fam from l where inv_key is not null group by 1, 2, 3, 4),
  ok as (select inv_key, min(im) im, coalesce(max(loc) filter (where loc > 0), 0) loc, min(fam) fam, sum(coalesce(basic, 0)) basic,
                sum(case when net > 0 then coalesce(basic, 0) * least(greatest(os / net, 0), 1) when os > 0 then coalesce(basic, 0) else 0 end) open_basic
         from ou group by 1),$o4$,
$o5$               coalesce(ok.basic, rk.basic, 0) basic, coalesce(ok.open_basic, 0) open_basic, coalesce(rk.collected, 0) collected, ok.inv_key is not null in_ledger$o5$,
$o6$    insert into bi.fin_inv_month as t (location_id, family, inv_month, inv_n, basic, open_basic, settled_basic, collected, in_ledger_n, receipt_only_n, run_id)
    select loc, fam, coalesce(im, date '1900-01-01'), count(*), sum(basic), sum(open_basic), sum(basic - open_basic), sum(collected),
           count(*) filter (where in_ledger), count(*) filter (where not in_ledger), v_run$o6$,
$o7$      settled_basic = excluded.settled_basic, collected = excluded.collected, in_ledger_n = excluded.in_ledger_n, receipt_only_n = excluded.receipt_only_n, run_id = v_run$o7$,
$o8$                            'ledger_lines', (select count(*) from l), 'receipts', (select count(*) from rc)) into c;$o8$,
$o9$  update bi.fin_os_agg set n = 0, basic = 0, net = 0, partial = 0, os = 0, os_basic = 0, neg_n = 0, neg_os = 0, dup_n = 0, dup_os = 0, run_id = v_run$o9$,
$o10$  update bi.fin_inv_month set inv_n = 0, basic = 0, open_basic = 0, settled_basic = 0, collected = 0, in_ledger_n = 0, receipt_only_n = 0, run_id = v_run$o10$];
  n := array[$n0$  rc0 as materialized (select u.id upload_id, x.*, row_number() over (partition by u.id, x.sheet, x.d, x.amt, coalesce(x.inv_key, ''), coalesce(x.h, '') order by x.r) dup_k
                       from unnest(v_co) u(id) cross join lateral bi.fin_receipts(u.id) x where x.role = 'bank'),
  rc as materialized (select distinct on (q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k) q.*
                      from rc0 q order by q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k, q.upload_id desc),
  m as materialized ($n0$,
$n1$    insert into bi.fin_os_agg as t (upload_id, location_id, family, inv_month, n, basic, net, partial, os, os_basic, neg_n, neg_os, dup_n, dup_os, run_id, gross, tds)
    select v_os, l.location_id, l.family, coalesce(l.im, date '1900-01-01'), count(*), coalesce(sum(l.basic), 0), coalesce(sum(l.net), 0), sum(l.partial), sum(l.os),$n1$,
$n2$           count(*) filter (where dk.c > 1), coalesce(sum(l.os * (dk.c - 1)::numeric / dk.c) filter (where dk.c > 1), 0), v_run,
           coalesce(sum(l.gross), 0), coalesce(sum(l.tds), 0)
    from l left join dk$n2$,
$n3$      os = excluded.os, os_basic = excluded.os_basic, neg_n = excluded.neg_n, neg_os = excluded.neg_os, dup_n = excluded.dup_n, dup_os = excluded.dup_os, run_id = v_run,
      gross = excluded.gross, tds = excluded.tds$n3$,
$n4$  ou as (select inv_key, basic, net, os, min(im) im, max(location_id) loc, min(family) fam, max(gross) gross, max(tds) tds from l where inv_key is not null group by 1, 2, 3, 4),
  ok as (select inv_key, min(im) im, coalesce(max(loc) filter (where loc > 0), 0) loc, min(fam) fam, sum(coalesce(basic, 0)) basic,
                sum(case when net > 0 then coalesce(basic, 0) * least(greatest(os / net, 0), 1) when os > 0 then coalesce(basic, 0) else 0 end) open_basic,
                sum(coalesce(gross, 0)) gross_l, sum(coalesce(tds, 0)) tds_l, sum(coalesce(net, 0)) net_l
         from ou group by 1),$n4$,
$n5$               coalesce(ok.basic, rk.basic, 0) basic, coalesce(ok.open_basic, 0) open_basic, coalesce(rk.collected, 0) collected, ok.inv_key is not null in_ledger,
               coalesce(ok.gross_l, 0) gross_l, coalesce(ok.tds_l, 0) tds_l, coalesce(ok.net_l, 0) net_l$n5$,
$n6$    insert into bi.fin_inv_month as t (location_id, family, inv_month, inv_n, basic, open_basic, settled_basic, collected, in_ledger_n, receipt_only_n, run_id, gross_l, tds_l, net_l)
    select loc, fam, coalesce(im, date '1900-01-01'), count(*), sum(basic), sum(open_basic), sum(basic - open_basic), sum(collected),
           count(*) filter (where in_ledger), count(*) filter (where not in_ledger), v_run, sum(gross_l), sum(tds_l), sum(net_l)$n6$,
$n7$      settled_basic = excluded.settled_basic, collected = excluded.collected, in_ledger_n = excluded.in_ledger_n, receipt_only_n = excluded.receipt_only_n, run_id = v_run,
      gross_l = excluded.gross_l, tds_l = excluded.tds_l, net_l = excluded.net_l$n7$,
$n8$                            'ledger_lines', (select count(*) from l), 'receipts', (select count(*) from rc),
                            'receipts_repeated_across_uploads', (select count(*) from rc0) - (select count(*) from rc)) into c;$n8$,
$n9$  update bi.fin_os_agg set n = 0, basic = 0, net = 0, partial = 0, os = 0, os_basic = 0, neg_n = 0, neg_os = 0, dup_n = 0, dup_os = 0, run_id = v_run, gross = 0, tds = 0$n9$,
$n10$  update bi.fin_inv_month set inv_n = 0, basic = 0, open_basic = 0, settled_basic = 0, collected = 0, in_ledger_n = 0, receipt_only_n = 0, run_id = v_run, gross_l = 0, tds_l = 0, net_l = 0$n10$];
  for i in 1 .. array_length(o, 1) loop
    if position(o[i] in d) = 0 then raise exception 'fin_derive fragment % not found', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;


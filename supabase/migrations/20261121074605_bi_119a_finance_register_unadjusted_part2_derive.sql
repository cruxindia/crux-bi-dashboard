-- Applied to Supabase project via MCP on 20261121074605
create or replace function bi.fin_derive(p_actor text default 'system'::text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '170s' as $function$
declare v_run bigint; v_os bigint; v_asof date; v_co bigint[]; v_sr bigint; v_ua bigint; v_rfrom date; v_rthru date; v_grace int; t0 timestamptz := clock_timestamp(); c jsonb; s jsonb;
begin
  perform bi.fin_apply_duplicate_rule('derive: ' || coalesce(p_actor, 'unknown'));
  v_grace := coalesce((select (value #>> '{}')::int from bi.fin_config where key = 'recon_grace_days'), 7);
  insert into bi.fin_run (actor) values (p_actor) returning id into v_run;
  select id, as_of into v_os, v_asof from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select array_agg(id order by id) into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;
  select id into v_ua from bi.fin_upload where kind = 'unadjusted' and status = 'committed' order by as_of desc, id desc limit 1;
  select min(coalesce(period_from, as_of)), max(as_of) into v_rfrom, v_rthru from bi.fin_upload where kind = 'collection' and status = 'committed';
  v_co := coalesce(v_co, '{}'::bigint[]); v_asof := coalesce(v_asof, current_date);

  with l as materialized (select * from bi.fin_os_lines(v_os)),
  dk as materialized (select inv_key, basic, net, os, count(*) c, jsonb_agg(jsonb_build_object('sheet', sheet, 'row', r)) rows_, max(location_id) loc
                      from l where inv_key is not null group by 1, 2, 3, 4),
  osk as materialized (select inv_key, sum(partial) partial, max(location_id) filter (where location_id > 0) loc from l where inv_key is not null group by 1),
  rc0 as materialized (select u.id upload_id, x.*, row_number() over (partition by u.id, x.sheet, x.d, x.amt, coalesce(x.inv_key, ''), coalesce(x.h, '') order by x.r) dup_k
                       from unnest(v_co) u(id) cross join lateral bi.fin_receipts(u.id) x where x.role = 'bank'),
  rc as materialized (select distinct on (q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k) q.*
                      from rc0 q order by q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k, q.upload_id desc),
  m as materialized (
    select rc.upload_id, rc.sheet, rc.r, rc.loc, rc.rm, rc.d, rc.amt, rc.inv, rc.inv_key, rc.basic, rc.im, rc.h, rc.family,
           coalesce(bi.fin_bank_family(rc.bank), bi.fin_bank_family(rc.sheet)) bfam,
           coalesce(case when rc.inv_key is not null then o.loc end, nullif(rc.map_loc, 0), 0) location_id,
           case when rc.inv_key is not null and o.loc is not null then 'ledger' else rc.map_state end loc_src,
           case when rc.inv_key is null then 'none' when o.inv_key is null then 'closed' when o.partial > 0.5 then 'partial'
                when rc.d is not null and rc.d <= v_asof - v_grace then 'open' else 'recent' end mstat,
           case when rc.d is not null and rc.im is not null then greatest(rc.d - (rc.im + interval '1 month' - interval '1 day')::date, 0) end lag
    from rc left join osk o on o.inv_key = rc.inv_key),
  s0 as materialized (select * from bi.fin_sales_lines(v_sr) where v_sr is not null),
  sdup as materialized (select inv_key, basic, net, os, lower(coalesce(cl, '')) lcl, count(*) c, min(r) r1, min(location_id) loc from s0 where inv_key is not null group by 1, 2, 3, 4, 5),
  rkl as materialized (select inv_key, max(location_id) filter (where location_id > 0) loc from m where inv_key is not null group by 1),
  sl as materialized (
    select s0.inv_key, min(s0.im) im, min(s0.family) fam, max(s0.basic) basic, max(s0.net) net, max(s0.os) os, max(s0.partial) partial, bool_or(s0.rk ~* '^\s*paid') paid,
           max(s0.location_id) loc, min(s0.loc_src) src
      from s0 where s0.inv_key is not null group by s0.inv_key, s0.basic, s0.net, s0.os, lower(coalesce(s0.cl, ''))),
  sl2 as materialized (select sl.*, coalesce(z.is_rollup, false) rollup from sl left join bi.location z on z.id = sl.loc),
  sk as materialized (
    select sl2.inv_key, min(sl2.im) im, min(sl2.fam) fam, sum(coalesce(sl2.basic, 0)) basic, count(*) lines,
           sum(case when sl2.paid then 0 when sl2.net > 0 then coalesce(sl2.basic, 0) * least(greatest(coalesce(sl2.os, sl2.net - coalesce(sl2.partial, 0)) / sl2.net, 0), 1) else coalesce(sl2.basic, 0) end) reg_open,
           coalesce(max(sl2.loc) filter (where sl2.loc > 0 and not sl2.rollup), max(o2.loc), max(r2.loc), max(sl2.loc) filter (where sl2.loc > 0), 0) loc,
           case when max(sl2.loc) filter (where sl2.loc > 0 and not sl2.rollup) is not null then min(sl2.src)
                when max(o2.loc) is not null then 'same invoice in the ledger' when max(r2.loc) is not null then 'same invoice in receipts'
                when max(sl2.loc) filter (where sl2.loc > 0) is not null then min(sl2.src) else 'none' end src
      from sl2 left join osk o2 on o2.inv_key = sl2.inv_key left join rkl r2 on r2.inv_key = sl2.inv_key group by sl2.inv_key),
  i_os as (
    insert into bi.fin_os_agg as t (upload_id, location_id, family, inv_month, n, basic, net, partial, os, os_basic, neg_n, neg_os, dup_n, dup_os, run_id, gross, tds)
    select v_os, l.location_id, l.family, coalesce(l.im, date '1900-01-01'), count(*), coalesce(sum(l.basic), 0), coalesce(sum(l.net), 0), sum(l.partial), sum(l.os),
           sum(case when l.net > 0 then coalesce(l.basic, 0) * least(greatest(l.os / l.net, 0), 1) when l.os > 0 then coalesce(l.basic, 0) else 0 end),
           count(*) filter (where l.os < 0), coalesce(sum(l.os) filter (where l.os < 0), 0),
           count(*) filter (where dk.c > 1), coalesce(sum(l.os * (dk.c - 1)::numeric / dk.c) filter (where dk.c > 1), 0), v_run,
           coalesce(sum(l.gross), 0), coalesce(sum(l.tds), 0)
    from l left join dk on dk.inv_key = l.inv_key and dk.basic is not distinct from l.basic and dk.net is not distinct from l.net and dk.os = l.os
    where v_os is not null
    group by 2, 3, 4
    on conflict (upload_id, location_id, family, inv_month) do update set n = excluded.n, basic = excluded.basic, net = excluded.net, partial = excluded.partial,
      os = excluded.os, os_basic = excluded.os_basic, neg_n = excluded.neg_n, neg_os = excluded.neg_os, dup_n = excluded.dup_n, dup_os = excluded.dup_os, run_id = v_run,
      gross = excluded.gross, tds = excluded.tds
    returning 1),
  i_un as (
    insert into bi.fin_unadj as t (upload_id, label, location_id, amount, run_id)
    select v_os, sh.key || ' · ' || coalesce(u->>'label', ''),
           coalesce(case when coalesce(u->>'label', '') ~* 'unadj' or jsonb_array_length(sh.value->'unadj') = 1 then sm.location_id end, lm.location_id, 0),
           coalesce((u->>'amount')::numeric, 0), v_run
    from bi.fin_upload fu cross join lateral jsonb_each(coalesce(fu.controls->'sheets', '{}'::jsonb)) sh
    cross join lateral jsonb_array_elements(coalesce(sh.value->'unadj', '[]'::jsonb)) u
    left join bi.fin_loc_map sm on sm.key_type = 'sheet' and sm.key = bi.fin_label(sh.key)
    left join bi.fin_loc_map lm on lm.key_type = 'label' and lm.key = bi.fin_label(u->>'label')
    where fu.id = v_os
    on conflict (upload_id, label) do update set location_id = excluded.location_id, amount = excluded.amount, run_id = v_run
    returning 1),
  i_rc as (
    insert into bi.fin_rcpt_agg as t (upload_id, location_id, family, bank, rcpt_month, n, amount, inv_n, inv_amount, basic,
                                      closed_n, closed_amount, partial_n, partial_amount, open_n, open_amount, lag_x_amount, lag_amount, run_id)
    select m.upload_id, m.location_id, m.family, m.sheet, coalesce(m.rm, date '1900-01-01'),
           count(*), sum(m.amt), count(*) filter (where m.inv_key is not null), coalesce(sum(m.amt) filter (where m.inv_key is not null), 0),
           coalesce(sum(m.basic) filter (where m.inv_key is not null), 0),
           count(*) filter (where m.mstat = 'closed'), coalesce(sum(m.amt) filter (where m.mstat = 'closed'), 0),
           count(*) filter (where m.mstat = 'partial'), coalesce(sum(m.amt) filter (where m.mstat = 'partial'), 0),
           count(*) filter (where m.mstat = 'open'), coalesce(sum(m.amt) filter (where m.mstat = 'open'), 0),
           coalesce(sum(m.lag * m.amt) filter (where m.lag is not null and m.amt > 0), 0), coalesce(sum(m.amt) filter (where m.lag is not null and m.amt > 0), 0), v_run
    from m group by 1, 2, 3, 4, 5
    on conflict (upload_id, location_id, family, bank, rcpt_month) do update set n = excluded.n, amount = excluded.amount, inv_n = excluded.inv_n,
      inv_amount = excluded.inv_amount, basic = excluded.basic, closed_n = excluded.closed_n, closed_amount = excluded.closed_amount, partial_n = excluded.partial_n,
      partial_amount = excluded.partial_amount, open_n = excluded.open_n, open_amount = excluded.open_amount, lag_x_amount = excluded.lag_x_amount,
      lag_amount = excluded.lag_amount, run_id = v_run
    returning 1),
  ou as (select inv_key, basic, net, os, min(im) im, max(location_id) loc, min(family) fam, max(gross) gross, max(tds) tds from l where inv_key is not null group by 1, 2, 3, 4),
  ok as (select inv_key, min(im) im, coalesce(max(loc) filter (where loc > 0), 0) loc, min(fam) fam, sum(coalesce(basic, 0)) basic,
                sum(case when net > 0 then coalesce(basic, 0) * least(greatest(os / net, 0), 1) when os > 0 then coalesce(basic, 0) else 0 end) open_basic,
                sum(coalesce(gross, 0)) gross_l, sum(coalesce(tds, 0)) tds_l, sum(coalesce(net, 0)) net_l
         from ou group by 1),
  rk as (select inv_key, min(im) im, coalesce(max(location_id) filter (where location_id > 0), 0) loc, min(family) fam, max(coalesce(basic, 0)) basic, sum(amt) collected
         from m where inv_key is not null group by 1),
  k as (select coalesce(nullif(ok.loc, 0), nullif(sk.loc, 0), rk.loc, 0) loc, coalesce(ok.fam, sk.fam, rk.fam, '(none)') fam, coalesce(ok.im, sk.im, rk.im) im,
               coalesce(sk.basic, ok.basic, rk.basic, 0) basic,
               case when ok.inv_key is not null or rk.inv_key is not null then coalesce(ok.basic, rk.basic, 0) else 0 end traced_basic,
               coalesce(ok.open_basic, 0) open_basic, coalesce(rk.collected, 0) collected, ok.inv_key is not null in_ledger, rk.inv_key is not null in_receipts,
               sk.inv_key is not null in_register, coalesce(sk.basic, 0) reg_basic, coalesce(sk.reg_open, 0) reg_open,
               coalesce(ok.gross_l, 0) gross_l, coalesce(ok.tds_l, 0) tds_l, coalesce(ok.net_l, 0) net_l
        from ok full join rk on rk.inv_key = ok.inv_key full join sk on sk.inv_key = coalesce(ok.inv_key, rk.inv_key)),
  i_inv as (
    insert into bi.fin_inv_month as t (location_id, family, inv_month, inv_n, basic, open_basic, settled_basic, collected, in_ledger_n, receipt_only_n, run_id, gross_l, tds_l, net_l,
                                       traced_basic, reg_basic, reg_n, untraced_basic, untraced_n, reg_open_basic)
    select loc, fam, coalesce(im, date '1900-01-01'), count(*), sum(basic), sum(open_basic), sum(traced_basic - open_basic), sum(collected),
           count(*) filter (where in_ledger), count(*) filter (where not in_ledger and in_receipts), v_run, sum(gross_l), sum(tds_l), sum(net_l),
           sum(traced_basic), sum(reg_basic), count(*) filter (where in_register), coalesce(sum(basic) filter (where in_register and not in_ledger and not in_receipts), 0),
           count(*) filter (where in_register and not in_ledger and not in_receipts), sum(reg_open)
    from k group by 1, 2, 3
    on conflict (location_id, family, inv_month) do update set inv_n = excluded.inv_n, basic = excluded.basic, open_basic = excluded.open_basic,
      settled_basic = excluded.settled_basic, collected = excluded.collected, in_ledger_n = excluded.in_ledger_n, receipt_only_n = excluded.receipt_only_n, run_id = v_run,
      gross_l = excluded.gross_l, tds_l = excluded.tds_l, net_l = excluded.net_l, traced_basic = excluded.traced_basic, reg_basic = excluded.reg_basic, reg_n = excluded.reg_n,
      untraced_basic = excluded.untraced_basic, untraced_n = excluded.untraced_n, reg_open_basic = excluded.reg_open_basic
    returning 1),
  u0 as materialized (select * from bi.fin_unadj_lines(v_ua) where v_ua is not null),
  rcm as materialized (select coalesce(bfam, '') bf, amt, d from m where d is not null and amt > 0),
  uhit as materialized (select u0.sheet, u0.r from u0 join rcm on rcm.bf = coalesce(u0.bfam, '') and rcm.amt = u0.amt and rcm.d between u0.d - 3 and u0.d + 3 group by 1, 2),
  udup as materialized (select coalesce(bfam, '') bf, d, amt, coalesce(h, '') hh, count(*) c from u0 where amt > 0 group by 1, 2, 3, 4 having count(*) > 1),
  um as materialized (
    select u0.*, case when uh.r is not null then 'in_receipts'
                      when u0.d is not null and v_rfrom is not null and u0.d < v_rfrom then 'before_receipts'
                      when u0.d is not null and v_rthru is not null and u0.d > v_rthru then 'after_receipts' else 'not_found' end status,
           ud.c dupc
      from u0 left join uhit uh on uh.sheet = u0.sheet and uh.r = u0.r
              left join udup ud on ud.bf = coalesce(u0.bfam, '') and ud.d = u0.d and ud.amt = u0.amt and ud.hh = coalesce(u0.h, '')),
  i_ut as (
    insert into bi.fin_unadj_txn as t (upload_id, location_id, family, bank, rcpt_month, status, n, amount, dup_n, dup_amount, run_id)
    select v_ua, location_id, family, coalesce(bfam, '(none)'), coalesce(rm, date_trunc('month', d)::date, date '1900-01-01'), status, count(*), sum(amt),
           count(*) filter (where dupc > 1), coalesce(sum(amt * (dupc - 1)::numeric / dupc) filter (where dupc > 1), 0), v_run
      from um group by 2, 3, 4, 5, 6
    on conflict (upload_id, location_id, family, bank, rcpt_month, status) do update set n = excluded.n, amount = excluded.amount, dup_n = excluded.dup_n, dup_amount = excluded.dup_amount, run_id = v_run
    returning 1),
  rv as (
    select 'map_location' kind, x.k key, null::bigint upload_id, 0 location_id, 'warn' severity, sum(x.amt) amount, count(*)::int n,
           'Location not identified: ' || x.k title, jsonb_build_object('source', min(x.src), 'examples', (array_agg(x.inv order by x.amt desc nulls last))[1:5]) detail
    from (select 'label "' || coalesce(bi.fin_label(l.loc), '(blank)') || '" / series ' || coalesce(l.prefix, '(none)') || ' / sheet "' || l.sheet || '"' k,
                 l.os amt, 'outstanding' src, l.inv from l where l.location_id = 0
          union all
          select 'label "' || coalesce(bi.fin_label(m.loc), '(blank)') || '" / series ' || coalesce(substring(m.inv_key from '^[A-Z]{2,5}'), '(none)'),
                 m.amt, 'receipts', m.inv from m where m.location_id = 0 and m.loc_src <> 'unallocated'
          union all
          select 'sales register / series ' || coalesce(substring(sk.inv_key from '^[A-Z]{2,5}'), '(none)'), sk.basic, 'sales register', sk.inv_key from sk where sk.loc = 0
          union all
          select 'unadjusted receipts / label "' || coalesce(u0.loc, '(blank)') || '"', u0.amt, 'unadjusted', null from u0 where u0.location_id = 0) x
    group by x.k
    union all
    select 'receipt_still_open', m.inv_key, min(m.upload_id), max(m.location_id), 'warn', sum(m.amt), count(*)::int,
           'Receipt recorded but invoice ' || m.inv_key || ' is still fully open in the ' || to_char(v_asof, 'DD-Mon-YYYY') || ' ledger',
           jsonb_build_object('receipts', jsonb_agg(jsonb_build_object('sheet', m.sheet, 'row', m.r, 'date', m.d, 'amount', m.amt) order by m.d), 'invoice', min(m.inv))
    from m where m.mstat = 'open' group by m.inv_key
    union all
    select 'duplicate_line', v_os || ':' || dk.inv_key || ':' || dk.os, v_os, dk.loc, 'warn', dk.os * (dk.c - 1), dk.c::int,
           'Invoice ' || dk.inv_key || ' appears ' || dk.c || ' times with identical amounts', jsonb_build_object('sheet_rows', dk.rows_, 'open_each', dk.os)
    from dk where dk.c > 1
    union all
    select 'register_repeated_line', v_sr || ':' || sdup.inv_key || ':' || coalesce(sdup.basic::text, '') || ':' || coalesce(sdup.os::text, '') || ':' || left(md5(sdup.lcl), 6), v_sr, sdup.loc, 'info', sdup.basic * (sdup.c - 1), sdup.c::int,
           'Sales register: invoice ' || sdup.inv_key || ' appears ' || sdup.c || ' times with identical amounts (billed once)', jsonb_build_object('first_row', sdup.r1)
    from sdup where sdup.c > 1
    union all
    select 'negative_balance', v_os || ':' || l.sheet || ':' || l.r, v_os, l.location_id, 'info', l.os, 1,
           'Negative open balance on ' || coalesce(l.inv_key, '(no invoice no.)'), jsonb_build_object('sheet', l.sheet, 'row', l.r, 'remark', l.rk)
    from l where l.os < 0
    union all
    select 'receipt_duplicate', x.upload_id || ':' || x.sheet || ':' || x.d || ':' || x.amt || ':' || x.h || ':' || coalesce(x.inv_key, ''), x.upload_id, max(x.location_id), 'warn',
           x.amt * (count(*) - 1), count(*)::int, 'Possible double entry on ' || x.sheet || ': ' || count(*) || ' identical credits of ' || x.amt || ' on ' || to_char(x.d, 'DD-Mon-YYYY'),
           jsonb_build_object('rows', jsonb_agg(x.r), 'invoice', min(x.inv))
    from m x where x.amt > 0 and x.d is not null group by x.upload_id, x.sheet, x.d, x.amt, x.h, x.inv_key having count(*) > 1
    union all
    select 'unadj_repeated', v_ua || ':' || um.location_id, v_ua, um.location_id, 'warn', sum(um.amt * (um.dupc - 1)::numeric / um.dupc), count(*)::int,
           'Unadjusted receipts: ' || count(*) || ' lines repeat another credit (same bank, date, amount and narration)', jsonb_build_object('rows', (array_agg(um.r order by um.r))[1:20])
    from um where um.dupc > 1 group by um.location_id
    union all
    select 'unadj_not_found', v_ua || ':' || um.location_id, v_ua, um.location_id, 'info', sum(um.amt), count(*)::int,
           'Unadjusted receipts not found in the receipt files (same bank, amount, date ± 3 days): ' || count(*) || ' lines',
           jsonb_build_object('months', (select jsonb_object_agg(mo, a) from (select to_char(coalesce(z.rm, z.d), 'YYYY-MM') mo, round(sum(z.amt)) a from um z where z.status = 'not_found' and z.location_id = um.location_id group by 1) q))
    from um where um.status = 'not_found' group by um.location_id
    union all
    select case when x.inv_key !~ '^[A-Z]{2,5}-[0-9]{4}-' then 'odd_invoice_ref' else 'multi_invoice_ref' end, x.upload_id || ':' || x.sheet || ':' || x.r, x.upload_id, x.location_id, 'info', x.amt, 1,
           case when x.inv_key !~ '^[A-Z]{2,5}-[0-9]{4}-' then 'Unreadable invoice reference "' || x.inv || '"' else 'One receipt quotes several invoices: "' || x.inv || '"' end,
           jsonb_build_object('sheet', x.sheet, 'row', x.r, 'date', x.d)
    from m x where x.inv is not null and (x.inv_key !~ '^[A-Z]{2,5}-[0-9]{4}-' or upper(x.inv) ~ '[,&]|\mAND\M|\s/\s')
    union all
    select 'control', fu.id || ':' || coalesce(i->>'rule', '') || ':' || coalesce(i->>'sheet', ''), fu.id, null, coalesce(i->>'severity', 'info'), null, null,
           fu.file_name || ': ' || coalesce(i->>'rule', 'check'), i
    from bi.fin_upload fu cross join lateral jsonb_array_elements(coalesce(fu.controls->'issues', '[]'::jsonb)) i
    where fu.id = v_os or fu.id = any (v_co) or fu.id = v_sr or fu.id = v_ua),
  i_rv as (
    insert into bi.fin_review as t (kind, key, upload_id, location_id, severity, amount, n, title, detail, run_id)
    select kind, key, upload_id, location_id, severity, amount, n, title, detail, v_run from rv
    on conflict (kind, key) do update set upload_id = excluded.upload_id, location_id = excluded.location_id, severity = excluded.severity, amount = excluded.amount,
      n = excluded.n, title = excluded.title, detail = excluded.detail, last_seen = now(), run_id = v_run,
      status = case when t.status = 'cleared' then 'open' else t.status end
    returning 1)
  select jsonb_build_object('os_groups', (select count(*) from i_os), 'unadj_rows', (select count(*) from i_un), 'receipt_groups', (select count(*) from i_rc),
                            'invoice_groups', (select count(*) from i_inv), 'review_items', (select count(*) from i_rv),
                            'ledger_lines', (select count(*) from l), 'receipts', (select count(*) from rc),
                            'receipts_repeated_across_uploads', (select count(*) from rc0) - (select count(*) from rc),
                            'register_lines', (select count(*) from s0), 'register_invoices', (select count(*) from sk), 'register_basic', (select round(sum(basic)) from sk),
                            'unadjusted_lines', (select count(*) from u0), 'unadjusted_groups', (select count(*) from i_ut)) into c;

  update bi.fin_os_agg set n = 0, basic = 0, net = 0, partial = 0, os = 0, os_basic = 0, neg_n = 0, neg_os = 0, dup_n = 0, dup_os = 0, run_id = v_run, gross = 0, tds = 0
   where run_id is distinct from v_run and (n <> 0 or os <> 0);
  update bi.fin_unadj set amount = 0, run_id = v_run where run_id is distinct from v_run and amount <> 0;
  update bi.fin_unadj_txn set n = 0, amount = 0, dup_n = 0, dup_amount = 0, run_id = v_run where run_id is distinct from v_run and (n <> 0 or amount <> 0);
  update bi.fin_rcpt_agg set n = 0, amount = 0, inv_n = 0, inv_amount = 0, basic = 0, closed_n = 0, closed_amount = 0, partial_n = 0, partial_amount = 0,
         open_n = 0, open_amount = 0, lag_x_amount = 0, lag_amount = 0, run_id = v_run
   where run_id is distinct from v_run and (n <> 0 or amount <> 0);
  update bi.fin_inv_month set inv_n = 0, basic = 0, open_basic = 0, settled_basic = 0, collected = 0, in_ledger_n = 0, receipt_only_n = 0, run_id = v_run, gross_l = 0, tds_l = 0, net_l = 0,
         traced_basic = 0, reg_basic = 0, reg_n = 0, untraced_basic = 0, untraced_n = 0, reg_open_basic = 0
   where run_id is distinct from v_run and inv_n <> 0;
  update bi.fin_review set status = 'cleared', run_id = v_run where run_id is distinct from v_run and status = 'open';

  c := coalesce(c, '{}'::jsonb) || jsonb_build_object('attribution', bi.fin_attr_refresh(v_os, v_co));
  s := jsonb_build_object('run', v_run, 'outstanding_upload', v_os, 'as_of', v_asof, 'collection_uploads', to_jsonb(v_co), 'sales_upload', v_sr, 'unadjusted_upload', v_ua,
         'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int) || c;
  update bi.fin_run set finished_at = clock_timestamp(), summary = s where id = v_run;
  return s;
end $function$;

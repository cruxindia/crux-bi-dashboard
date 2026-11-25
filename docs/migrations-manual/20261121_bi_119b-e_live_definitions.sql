-- Waves 119b–119e (21-Nov-2026), applied as small patches on the same day; this file records the live definitions as of 25-Nov-2026
-- (they supersede the versions of these functions in 20261121_bi_119a_finance_register_unadjusted.sql).
-- 119b: bi.fin_upload_compare — month comparison rewritten with CTEs (nested aggregates failed at commit).
-- 119c: the rebuild runs in the background every 2 minutes (cron job bi-fin-derive → bi.fin_derive_if_stale); bi.api_fin_sources reports last_rebuild / rebuild_pending.
-- 119d: bi.fin_derive_if_stale writes an audit row so cached figures refresh; public.bi_call serves fin_sources uncached.
-- 119e: register months = the sales register only (bi.fin_config register_months_register_only; nreg_basic kept for the comparison) in bi.fin_derive, bi.fin_attr_refresh, bi.api_fin_sources.
-- Rebuild: run this file after 119a.

CREATE OR REPLACE FUNCTION bi.api_fin_sources(f jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'bi', 'public'
AS $function$
  with sr as (select * from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1),
       ua as (select * from bi.fin_upload where kind = 'unadjusted' and status = 'committed' order by as_of desc, id desc limit 1),
       os as (select * from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1),
       locs as (select l.id from bi.location l where bi.fin_loc_ok(l.id, coalesce(f, '{}'::jsonb)) union select 0 where coalesce(f, '{}'::jsonb) - 'month' = '{}'::jsonb),
       reg as (select i.inv_month mo, sum(i.reg_basic) reg, sum(i.reg_n) reg_n, sum(i.traced_basic) traced, sum(i.untraced_basic) untraced, sum(i.untraced_n) untraced_n,
                      sum(i.reg_open_basic) reg_open, sum(i.open_basic) ledger_open, sum(i.settled_basic) settled, sum(i.basic) billed, sum(coalesce(i.nreg_basic, 0)) nreg
                 from bi.fin_inv_month i where i.inv_n > 0 and i.location_id in (select id from locs) and (f->>'client_family' is null or i.family = f->>'client_family')
                  and i.inv_month between coalesce((select period_from from sr), date '2100-01-01') and coalesce((select period_to from sr), date '1900-01-01') group by 1),
       ut as (select t.status, t.location_id, t.bank, t.rcpt_month, t.n, t.amount, t.dup_n, t.dup_amount from bi.fin_unadj_txn t
               where t.upload_id = (select id from ua) and t.n > 0 and t.location_id in (select id from locs))
  select jsonb_build_object(
    'sales_register', (select jsonb_build_object('upload', sr.id, 'file', sr.file_name, 'as_of', sr.as_of, 'from', sr.period_from, 'to', sr.period_to,
        'billed', (select round(sum(reg)) from reg), 'invoices', (select sum(reg_n) from reg), 'traced', (select round(sum(traced)) from reg),
        'status_not_traced', (select round(sum(untraced)) from reg), 'status_not_traced_n', (select sum(untraced_n) from reg),
        'open_per_register', (select round(sum(reg_open)) from reg), 'open_per_ledger', (select round(sum(ledger_open)) from reg),
        'traced_not_in_register', (select round(sum(nreg)) from reg),
        'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'billed', round(reg), 'invoices', reg_n, 'traced', round(traced), 'status_not_traced', round(untraced),
                     'settled', round(settled), 'open_per_ledger', round(ledger_open), 'open_per_register', round(reg_open), 'traced_not_in_register', round(nreg),
                     'realisation_traced', case when traced > 0 then round(settled / traced, 3) end, 'register_settled_share', case when reg > 0 then round(1 - reg_open / reg, 3) end) order by mo) from reg),
        'outstanding_used', false,
        'note', 'Billed revenue for these months comes from the register (each invoice once). Its "Actual Outstanding" and paid / pending remarks are not maintained ' ||
                '(they equal Net on most lines, also on lines marked paid), so receivables come from the outstanding workbook of ' || coalesce(to_char((select as_of from os), 'DD-Mon-YYYY'), '—') || '.',
        'issues', sr.controls->'issues') from sr),
    'unadjusted', (select jsonb_build_object('upload', ua.id, 'file', ua.file_name, 'as_of', ua.as_of, 'from', ua.period_from, 'to', ua.period_to,
        'total', (select round(sum(amount)) from ut), 'lines', (select sum(n) from ut),
        'in_receipts', (select round(sum(amount)) from ut where status = 'in_receipts'), 'before_receipts', (select round(sum(amount)) from ut where status = 'before_receipts'),
        'after_receipts', (select round(sum(amount)) from ut where status = 'after_receipts'), 'not_found', (select round(sum(amount)) from ut where status = 'not_found'),
        'repeated', (select round(sum(dup_amount)) from ut), 'location_not_identified', (select round(sum(amount)) from ut where location_id = 0),
        'by_location', (select jsonb_agg(x order by (x->>'amount')::numeric desc) from (select jsonb_build_object('location_id', ut.location_id, 'location', coalesce(l.label, 'Location not identified'),
                          'amount', round(sum(ut.amount)), 'lines', sum(ut.n), 'in_receipts', round(coalesce(sum(ut.amount) filter (where ut.status = 'in_receipts'), 0)),
                          'older_than_90_days', round(coalesce(sum(ut.amount) filter (where ut.rcpt_month < (date_trunc('month', ua.as_of) - interval '2 months')::date), 0))) x
                          from ut left join bi.location l on l.id = ut.location_id group by ut.location_id, l.label) q),
        'by_month', (select jsonb_agg(jsonb_build_object('month', rcpt_month, 'amount', a, 'in_receipts', ir) order by rcpt_month) from (select rcpt_month, round(sum(amount)) a, round(coalesce(sum(amount) filter (where status = 'in_receipts'), 0)) ir from ut group by 1) q),
        'note', 'Money already in the bank that is not yet applied to an invoice. It is part of cash collected (never added to it); "in receipts" = found in the receipt files by bank, amount and date ± 3 days.',
        'issues', ua.controls->'issues') from ua),
    'last_rebuild', (select jsonb_build_object('run', r.id, 'finished_at', r.finished_at, 'ms', r.summary->'ms') from bi.fin_run r where r.finished_at is not null order by r.id desc limit 1),
    'rebuild_pending', (select max(committed_at) from bi.fin_upload) > coalesce((select max(finished_at) from bi.fin_run), '-infinity'),
    'uploads', (select jsonb_agg(jsonb_build_object('upload', u.id, 'kind', u.kind, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status, 'committed_at', u.committed_at, 'notes', u.notes) order by u.id desc)
                  from (select * from bi.fin_upload where status in ('committed', 'superseded') order by id desc limit 12) u)) $function$
;

CREATE OR REPLACE FUNCTION public.bi_call(p_fn text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'bi', 'public'
 SET statement_timeout TO '45s'
AS $function$
declare m date := nullif(p_args->>'month','')::date; f jsonb := coalesce(p_args->'filters','{}');
        v_admin boolean := bi.admin_ok(p_args->>'admin_key');
        v_team int := nullif(p_args->>'team', '')::int;   -- wave 102p: drill-down into one team, served from the page's cached figure
        v_ver bigint := bi.cache_version();
        v_key text := md5(p_fn || '|' || coalesce((p_args - 'admin_key' - 'team')::text,''));
        r jsonb; c_ver bigint; c_at timestamptz;
begin
  if p_fn in ('exceptions','mapping_queue','branch_reviews','fin_review','fin_records') then
    if not v_admin then return jsonb_build_object('error','admin key required'); end if;
    return case p_fn when 'exceptions' then bi.api_exceptions() when 'fin_review' then bi.api_fin_review(coalesce(p_args->'p', '{}'::jsonb)) when 'fin_records' then bi.api_fin_records(coalesce(p_args->'p', '{}'::jsonb)) when 'branch_reviews' then bi.branch_admin('viewer', jsonb_build_object('op','review_list','status',coalesce(p_args->>'status','open'),'family',p_args->>'family','limit',p_args->>'limit')) else bi.api_mapping_queue() end;
  end if;
  if p_fn = 'identity' then return bi.api_identity(); end if;
  if p_fn = 'consistency' then return bi.api_consistency(); end if;   -- wave 111b: latest same-figure-everywhere check
  if p_fn = 'coverage_status' then return bi.api_coverage_status(); end if;
  if p_fn = 'fin_sources' then return bi.api_fin_sources(f); end if;   -- wave 119d: small, shows the last rebuild; not cached
  if p_fn = 'branch_list' then return bi.api_branch_list(f, coalesce(p_args->'p', '{}'::jsonb)); end if;   -- wave 102f: large, filter-specific; not cached   -- latest identity run; not cached (runs do not change the data version)
  select v, version, computed_at into r, c_ver, c_at from bi.api_cache where k = v_key;
  -- wave 098: an older-version figure is served only when it is recent (24 h) and computed after the latest correction floor; otherwise compute now
  if r is not null and c_ver is distinct from v_ver
     and (c_at < now() - interval '24 hours' or c_at < (select coalesce(max(floor_at), '-infinity'::timestamptz) from bi.api_cache_floor)) then
    r := null;
  end if;
  if r is not null and c_ver is distinct from v_ver then
    -- an older data version: answer now with the last good result, recompute in the background (bi.api_revalidate)
    begin perform set_config('lock_timeout', '1500ms', true);
      insert into bi.api_cache_queue(k, fn, args) values (v_key, p_fn, p_args - 'admin_key' - 'team')
      on conflict (k) do update set requested_at = now(), done_at = null, last_error = null, fn = excluded.fn, args = excluded.args
       where bi.api_cache_queue.done_at is not null or bi.api_cache_queue.requested_at < now() - interval '30 minutes';
    exception when lock_not_available then null; end; perform set_config('lock_timeout', '0', true);
  elsif r is null then
    r := bi.call_compute(p_fn, p_args - 'team');
    if r is not null then
      begin perform set_config('lock_timeout', '1500ms', true); insert into bi.api_cache(k, v, version, fn, args) values (v_key, r, v_ver, p_fn, p_args - 'admin_key' - 'team')
      on conflict (k) do update set v = excluded.v, version = excluded.version, fn = excluded.fn, args = excluded.args, computed_at = now(); exception when lock_not_available then null; end; perform set_config('lock_timeout', '0', true);
    end if;
  end if;
  -- person-level split (Force1 activity per person): names for admins only, like the workforce view
  if p_fn = 'split' and not v_admin and r->>'level' = 'people' then
    r := r || jsonb_build_object('names_hidden', true,
      'members', (select coalesce(jsonb_agg((x - 'member') || jsonb_build_object('member', 'Person ' || (x->>'rank')) order by o), '[]'::jsonb) from jsonb_array_elements(r->'members') with ordinality t(x, o)),
      'groups', (select coalesce(jsonb_agg((x - 'top1' - 'carry50') || jsonb_build_object('top1', 'Person 1', 'carry50', null) order by o), '[]'::jsonb) from jsonb_array_elements(r->'groups') with ordinality t(x, o)));
  end if;
  -- penalty reasons and names of who entered them: admins only
  if p_fn = 'penalty' and not v_admin and jsonb_typeof(r->'entries') = 'array' then
    r := jsonb_set(r, '{entries}', (select coalesce(jsonb_agg((x - 'reason' - 'reference' - 'by') order by o), '[]'::jsonb) from jsonb_array_elements(r->'entries') with ordinality t(x, o)));
    r := r || jsonb_build_object('reasons_hidden', true);
  end if;
  -- leaver names are HR data: admins only
  if p_fn = 'attrition' and not v_admin and jsonb_typeof(r->'leavers') = 'array' then
    r := jsonb_set(r, '{leavers}', (select coalesce(jsonb_agg((x - 'name') || jsonb_build_object('name', '(admin only)') order by o), '[]'::jsonb) from jsonb_array_elements(r->'leavers') with ordinality t(x, o)));
    r := r || jsonb_build_object('names_hidden', true);
  end if;
  -- workforce names (Force1-based HR view): admins only
  if p_fn = 'workforce' and not v_admin and r ? 'absent_now' then
    r := r || jsonb_build_object('names_hidden', true,
      'absent_now', (select coalesce(jsonb_agg(x - 'name' || jsonb_build_object('name', '(admin only)') order by o), '[]'::jsonb) from jsonb_array_elements(r->'absent_now') with ordinality t(x, o)),
      'leavers',    (select coalesce(jsonb_agg(x - 'name' || jsonb_build_object('name', '(admin only)') order by o), '[]'::jsonb) from jsonb_array_elements(r->'leavers') with ordinality t(x, o)),
      'joiners',    (select coalesce(jsonb_agg(x - 'name' || jsonb_build_object('name', '(admin only)') order by o), '[]'::jsonb) from jsonb_array_elements(r->'joiners') with ordinality t(x, o)),
      'returned',   (select coalesce(jsonb_agg(x - 'name' || jsonb_build_object('name', '(admin only)') order by o), '[]'::jsonb) from jsonb_array_elements(r->'returned') with ordinality t(x, o)));
  end if;
  -- wave 102p: the suggested-target sheet and the plan by team x client are a full download for admins only; others see zone and team
  -- roll-ups and the client rows of one team at a time ('team' or a one-team page filter)
  if p_fn = 'target_sheet' and jsonb_typeof(r->'rows') = 'array' then
    if v_team is not null then
      r := r || jsonb_build_object('team', v_team,
             'rows', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(r->'rows') with ordinality t(x, o) where (x->>'location_id')::int = v_team));
      if jsonb_typeof(r->'opportunities'->'list') = 'array' then
        r := jsonb_set(r, '{opportunities,list}', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(r->'opportunities'->'list') with ordinality t(x, o)
                                                     where x->>'location' = (select l.label from bi.location l where l.id = v_team)));
      end if;
    elsif not v_admin and nullif(f->>'location_id', '') is null then
      r := r || jsonb_build_object('rows_hidden', true, 'by_zone', bi.sheet_roll(r->'rows', 'zone'), 'by_location', bi.sheet_roll(r->'rows', 'location'), 'rows', '[]'::jsonb);
      if jsonb_typeof(r->'opportunities'->'list') = 'array' then
        r := jsonb_set(r, '{opportunities,by_location}', (select coalesce(jsonb_agg(jsonb_build_object('zone_group', zg, 'location', loc, 'rows', n, 'pot_rev', pr, 'pot_cases', pc) order by pr desc), '[]'::jsonb)
                                                           from (select x->>'zone_group' zg, x->>'location' loc, count(*) n, sum((x->>'pot_rev')::numeric) pr, sum((x->>'pot_cases')::numeric) pc
                                                                   from jsonb_array_elements(r->'opportunities'->'list') x group by 1, 2) q));
        r := jsonb_set(r, '{opportunities,list}', '[]'::jsonb);
      end if;
    end if;
  end if;
  if p_fn = 'plan' and jsonb_typeof(r->'by_cell') = 'array' then
    if v_team is not null then
      r := r || jsonb_build_object('team', v_team,
             'by_cell', (select coalesce(jsonb_agg(x order by o), '[]'::jsonb) from jsonb_array_elements(r->'by_cell') with ordinality t(x, o) where (x->>'location_id')::int = v_team));
    elsif not v_admin and nullif(f->>'location_id', '') is null then
      r := (r - 'by_cell') || jsonb_build_object('by_cell_hidden', true);
    end if;
  end if;
  if p_fn = 'meta' then r := r || jsonb_build_object('role', case when v_admin then 'admin' else 'viewer' end); end if;
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION bi.fin_attr_refresh(p_os bigint DEFAULT NULL::bigint, p_co bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'bi', 'public'
 SET statement_timeout TO '170s'
AS $function$
declare v_os bigint := p_os; v_co bigint[] := p_co; v_sr bigint; v_rf date; v_rt date; v_run bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint; v_n int; t0 timestamptz := clock_timestamp();
begin
  if v_os is null then select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1; end if;
  if v_co is null then select coalesce(array_agg(id order by id), '{}') into v_co from bi.fin_upload where kind = 'collection' and status = 'committed'; end if;
  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;
  select period_from, period_to into v_rf, v_rt from bi.fin_upload where id = v_sr;
  with l as materialized (select * from bi.fin_os_lines(v_os)),
  rc0 as materialized (select u.id upload_id, x.*, row_number() over (partition by u.id, x.sheet, x.d, x.amt, coalesce(x.inv_key, ''), coalesce(x.h, '') order by x.r) dup_k
                       from unnest(v_co) u(id) cross join lateral bi.fin_receipts(u.id) x where x.role = 'bank'),
  rc as materialized (select distinct on (q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k) q.*
                      from rc0 q order by q.sheet, q.d, q.amt, coalesce(q.inv_key, ''), coalesce(q.h, ''), q.dup_k, q.upload_id desc),
  osk as materialized (select inv_key, max(location_id) filter (where location_id > 0) loc from l where inv_key is not null group by 1),
  ou as (select inv_key, basic, net, os, min(im) im, max(location_id) loc, min(family) fam, min(cl) cl, min(loc_src) src from l where inv_key is not null group by 1, 2, 3, 4),
  ok as (select inv_key, min(im) im, coalesce(max(loc) filter (where loc > 0), 0) loc, min(fam) fam, min(cl) cl, min(src) src, sum(coalesce(basic, 0)) basic from ou group by 1),
  rk as (select rc.inv_key, min(rc.im) im, coalesce(max(coalesce(o.loc, nullif(rc.map_loc, 0))), 0) loc, min(rc.family) fam, min(rc.cl) cl, max(coalesce(rc.basic, 0)) basic,
                min(case when o.loc is not null then 'ledger' else rc.map_state end) src
           from rc left join osk o on o.inv_key = rc.inv_key where rc.inv_key is not null group by 1),
  s0 as materialized (select * from bi.fin_sales_lines(v_sr) where v_sr is not null),
  sl as (select s0.inv_key, min(s0.im) im, min(s0.family) fam, min(s0.cl) cl, max(s0.basic) basic, max(s0.location_id) loc, min(s0.loc_src) src
           from s0 where s0.inv_key is not null group by s0.inv_key, s0.basic, s0.net, s0.os, lower(coalesce(s0.cl, ''))),
  sl2 as (select sl.*, coalesce(z.is_rollup, false) rollup from sl left join bi.location z on z.id = sl.loc),
  sk as (select sl2.inv_key, min(sl2.im) im, min(sl2.fam) fam, min(sl2.cl) cl, sum(coalesce(sl2.basic, 0)) basic,
                coalesce(max(sl2.loc) filter (where sl2.loc > 0 and not sl2.rollup), max(sl2.loc) filter (where sl2.loc > 0), 0) loc,
                bool_or(sl2.loc > 0 and not sl2.rollup) city_level, min(sl2.src) || ' (sales register)' src
           from sl2 group by sl2.inv_key),
  k as materialized (select coalesce(ok.inv_key, rk.inv_key, sk.inv_key) inv_key,
                            coalesce(nullif(ok.loc, 0), case when sk.city_level then sk.loc end, nullif(rk.loc, 0), nullif(sk.loc, 0), 0) loc,
                            coalesce(ok.fam, sk.fam, rk.fam, '(none)') fam, coalesce(ok.cl, sk.cl, rk.cl) cl,
                            coalesce(ok.im, sk.im, rk.im) im,
                            case when sk.inv_key is null and v_sr is not null and coalesce(ok.im, rk.im) between v_rf and v_rt then 0 else coalesce(sk.basic, ok.basic, rk.basic, 0) end basic,
                            coalesce(case when nullif(ok.loc, 0) is not null then ok.src end, case when sk.loc > 0 then sk.src end, rk.src, ok.src, sk.src, 'none') src
                       from ok full join rk on rk.inv_key = ok.inv_key full join sk on sk.inv_key = coalesce(ok.inv_key, rk.inv_key)),
  lines as (
    select 'billed'::text kind, 0::bigint upload_id, coalesce(k.im, date '1900-01-01') m, k.loc, k.fam, k.cl, k.basic amt, k.src from k
    union all
    select 'collected', rc.upload_id, coalesce(rc.rm, date '1900-01-01'), coalesce(case when rc.inv_key is not null then o.loc end, nullif(rc.map_loc, 0), 0),
           coalesce(ki.fam, rc.family), coalesce(ki.cl, rc.cl), rc.amt, case when rc.inv_key is not null and o.loc is not null then 'ledger' else rc.map_state end
      from rc left join osk o on o.inv_key = rc.inv_key left join k ki on ki.inv_key = rc.inv_key
    union all
    select 'outstanding', v_os, coalesce(l.im, date '1900-01-01'), l.location_id, l.family, l.cl, l.os, l.loc_src from l),
  g as materialized (select kind, upload_id, m, loc, fam, bi.fin_client_word(cl) w, src, sum(amt) amt, count(*) n from lines group by 1, 2, 3, 4, 5, 6, 7),
  keys as materialized (select distinct loc, fam, w, m from g where loc > 0),
  cand as (select k.loc, k.fam, k.w, k.m, v.client_code, sum(coalesce(v.revenue, 0)) rev, sum(coalesce(v.cases, 0)) cs
             from keys k join bi.client c on c.family = k.fam
             join bi.v_month_business v on v.location_id = k.loc and v.client_code = c.code and v.month between (k.m - interval '2 months')::date and k.m
            group by 1, 2, 3, 4, 5 having sum(coalesce(v.revenue, 0)) > 0 or sum(coalesce(v.cases, 0)) > 0),
  pick as (select distinct on (c.loc, c.fam, c.w, c.m) c.loc, c.fam, c.w, c.m, c.client_code,
                  case when count(*) over (partition by c.loc, c.fam, c.w, c.m) = 1 then 'only client of the family here'
                       when c.w is not null and bi.fin_client_fits(c.client_code, c.w) then 'client named in the text'
                       else 'largest client of the family here' end basis
             from cand c order by c.loc, c.fam, c.w, c.m, bi.fin_client_fits(c.client_code, c.w) desc, c.rev desc, c.cs desc),
  ins as (
    insert into bi.fin_attr as t (kind, upload_id, m, location_id, client_code, family, basis, client_basis, amt, n, run_id)
    select kind, upload_id, m, loc, cc, fam, src, min(cb), sum(amt), sum(n), v_run
      from (select g.kind, g.upload_id, g.m, g.loc, g.fam, coalesce(g.src, 'none') src, g.amt, g.n,
                   coalesce(p.client_code, case when g.loc > 0 and exists (select 1 from bi.client c where c.code = g.fam) then g.fam end, '') cc,
                   coalesce(p.basis, case when g.loc > 0 and exists (select 1 from bi.client c where c.code = g.fam) then 'family code (no tracker business here)' end) cb
              from g left join pick p on p.loc = g.loc and p.fam = g.fam and p.w is not distinct from g.w and p.m = g.m) z
     group by 1, 2, 3, 4, 5, 6, 7
    on conflict (kind, upload_id, m, location_id, client_code, family, basis) do update set amt = excluded.amt, n = excluded.n, client_basis = excluded.client_basis, run_id = v_run
    returning 1)
  select count(*) into v_n from ins;
  update bi.fin_attr set amt = 0, n = 0 where run_id is distinct from v_run and (amt <> 0 or n <> 0);
  return jsonb_build_object('rows', v_n, 'outstanding_upload', v_os, 'collection_uploads', to_jsonb(v_co), 'sales_upload', v_sr, 'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int);
end $function$
;

CREATE OR REPLACE FUNCTION bi.fin_billing_basis()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'bi', 'public'
AS $function$
  with os as (select id, as_of, file_name from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1),
       co as (select min(coalesce(period_from, as_of)) pfrom, max(as_of) thru, (array_agg(file_name order by as_of desc))[1] fname
              from bi.fin_upload where kind = 'collection' and status = 'committed'),
       sr as (select id, as_of, file_name, period_from, period_to from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1),
       cfg as (select coalesce((select (value #>> '{}')::int from bi.fin_config where key = 'billing_complete_days'), 30) d),
       b as (select os.id os_upload, os.as_of, os.file_name os_file, co.pfrom, co.thru, co.fname co_file, cfg.d,
                    (date_trunc('month', co.pfrom) - interval '1 month')::date first_complete,
                    (select max(g::date) from generate_series((date_trunc('month', co.pfrom) - interval '1 month')::date, date_trunc('month', os.as_of), interval '1 month') g
                      where (g + interval '1 month' - interval '1 day')::date + cfg.d <= os.as_of) last_by_snapshot
             from os, co, cfg)
  select jsonb_build_object('outstanding_upload', b.os_upload, 'as_of', b.as_of, 'outstanding_file', b.os_file,
           'receipts_from', b.pfrom, 'receipts_through', b.thru, 'collection_file', b.co_file, 'complete_days', b.d,
           'first_complete', least(b.first_complete, sr.period_from),
           'last_complete', greatest(b.last_by_snapshot, sr.period_to),
           'sales_upload', sr.id, 'sales_file', sr.file_name, 'sales_as_of', sr.as_of, 'sales_from', sr.period_from, 'sales_to', sr.period_to,
           'rule', 'An invoice month is completely billed from ' || to_char(b.first_complete, 'Mon-YYYY') ||
                   ' (receipts start ' || to_char(b.pfrom, 'DD-Mon-YYYY') || ', so earlier invoices that were already paid are missing) and once the outstanding snapshot is at least ' ||
                   b.d || ' days after the month end (snapshot ' || to_char(b.as_of, 'DD-Mon-YYYY') || ')' ||
                   coalesce('; the months in the sales register (' || to_char(sr.period_from, 'Mon-YYYY') || ' to ' || to_char(sr.period_to, 'Mon-YYYY') || ', file of ' || to_char(sr.as_of, 'DD-Mon-YYYY') || ') are complete', '') || '.')
  from b left join sr on true $function$
;

CREATE OR REPLACE FUNCTION bi.fin_derive(p_actor text DEFAULT 'system'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'bi', 'public'
 SET statement_timeout TO '170s'
AS $function$
declare v_run bigint; v_os bigint; v_asof date; v_co bigint[]; v_sr bigint; v_ua bigint; v_rf date; v_rt date; v_rfrom date; v_rthru date; v_grace int; t0 timestamptz := clock_timestamp(); c jsonb; s jsonb;
begin
  perform bi.fin_apply_duplicate_rule('derive: ' || coalesce(p_actor, 'unknown'));
  v_grace := coalesce((select (value #>> '{}')::int from bi.fin_config where key = 'recon_grace_days'), 7);
  insert into bi.fin_run (actor) values (p_actor) returning id into v_run;
  select id, as_of into v_os, v_asof from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1;
  select array_agg(id order by id) into v_co from bi.fin_upload where kind = 'collection' and status = 'committed';
  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;
  select period_from, period_to into v_rf, v_rt from bi.fin_upload where id = v_sr;   -- wave 119e: months the register covers
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
               case when sk.inv_key is null and v_sr is not null and coalesce(ok.im, rk.im) between v_rf and v_rt then 0 else coalesce(sk.basic, ok.basic, rk.basic, 0) end basic,
               case when sk.inv_key is null and v_sr is not null and coalesce(ok.im, rk.im) between v_rf and v_rt then coalesce(ok.basic, rk.basic, 0) else 0 end nreg_basic,
               case when ok.inv_key is not null or rk.inv_key is not null then coalesce(ok.basic, rk.basic, 0) else 0 end traced_basic,
               coalesce(ok.open_basic, 0) open_basic, coalesce(rk.collected, 0) collected, ok.inv_key is not null in_ledger, rk.inv_key is not null in_receipts,
               sk.inv_key is not null in_register, coalesce(sk.basic, 0) reg_basic, coalesce(sk.reg_open, 0) reg_open,
               coalesce(ok.gross_l, 0) gross_l, coalesce(ok.tds_l, 0) tds_l, coalesce(ok.net_l, 0) net_l
        from ok full join rk on rk.inv_key = ok.inv_key full join sk on sk.inv_key = coalesce(ok.inv_key, rk.inv_key)),
  i_inv as (
    insert into bi.fin_inv_month as t (location_id, family, inv_month, inv_n, basic, open_basic, settled_basic, collected, in_ledger_n, receipt_only_n, run_id, gross_l, tds_l, net_l,
                                       traced_basic, reg_basic, reg_n, untraced_basic, untraced_n, reg_open_basic, nreg_basic)
    select loc, fam, coalesce(im, date '1900-01-01'), count(*), sum(basic), sum(open_basic), sum(traced_basic - open_basic), sum(collected),
           count(*) filter (where in_ledger), count(*) filter (where not in_ledger and in_receipts), v_run, sum(gross_l), sum(tds_l), sum(net_l),
           sum(traced_basic), sum(reg_basic), count(*) filter (where in_register), coalesce(sum(basic) filter (where in_register and not in_ledger and not in_receipts), 0),
           count(*) filter (where in_register and not in_ledger and not in_receipts), sum(reg_open), sum(nreg_basic)
    from k group by 1, 2, 3
    on conflict (location_id, family, inv_month) do update set inv_n = excluded.inv_n, basic = excluded.basic, open_basic = excluded.open_basic,
      settled_basic = excluded.settled_basic, collected = excluded.collected, in_ledger_n = excluded.in_ledger_n, receipt_only_n = excluded.receipt_only_n, run_id = v_run,
      gross_l = excluded.gross_l, tds_l = excluded.tds_l, net_l = excluded.net_l, traced_basic = excluded.traced_basic, reg_basic = excluded.reg_basic, reg_n = excluded.reg_n,
      untraced_basic = excluded.untraced_basic, untraced_n = excluded.untraced_n, reg_open_basic = excluded.reg_open_basic, nreg_basic = excluded.nreg_basic
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
         traced_basic = 0, reg_basic = 0, reg_n = 0, untraced_basic = 0, untraced_n = 0, reg_open_basic = 0, nreg_basic = 0
   where run_id is distinct from v_run and inv_n <> 0;
  update bi.fin_review set status = 'cleared', run_id = v_run where run_id is distinct from v_run and status = 'open';

  c := coalesce(c, '{}'::jsonb) || jsonb_build_object('attribution', bi.fin_attr_refresh(v_os, v_co));
  s := jsonb_build_object('run', v_run, 'outstanding_upload', v_os, 'as_of', v_asof, 'collection_uploads', to_jsonb(v_co), 'sales_upload', v_sr, 'unadjusted_upload', v_ua,
         'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int) || c;
  update bi.fin_run set finished_at = clock_timestamp(), summary = s where id = v_run;
  return s;
end $function$
;

CREATE OR REPLACE FUNCTION bi.fin_derive_if_stale()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'bi', 'public'
AS $function$
declare last timestamptz := (select max(finished_at) from bi.fin_run); d jsonb;
begin
  if last is not null and last >= greatest(
       coalesce((select max(committed_at) from bi.fin_upload), '-infinity'), coalesce((select max(updated_at) from bi.fin_loc_map), '-infinity'),
       coalesce((select max(updated_at) from bi.fin_client_map), '-infinity'), coalesce((select max(updated_at) from bi.fin_config), '-infinity'), coalesce((select max(approved_at) from bi.fin_line_exclusion), '-infinity')) then
    return jsonb_build_object('stale', false);
  end if;
  if not exists (select 1 from bi.fin_upload where status = 'committed') then return jsonb_build_object('stale', false, 'uploads', 0); end if;
  d := bi.fin_derive('scheduled');
  insert into bi.audit_log (actor, action, entity, entity_key, detail) values ('scheduled', 'fin_derive', 'fin_run', d->>'run', d - 'attribution');   -- wave 119d: new data version
  return d;
end $function$
;

CREATE OR REPLACE FUNCTION bi.fin_upload_compare(p_upload bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'bi', 'public'
AS $function$
declare u bi.fin_upload; o bi.fin_upload; cur jsonb;
begin
  select * into u from bi.fin_upload where id = p_upload; if u.id is null then return null; end if;
  select * into o from bi.fin_upload x where x.kind = u.kind and x.id <> u.id and x.status in ('committed', 'superseded')
     and (u.kind <> 'collection' or bi.fin_fy(coalesce(x.period_from, x.as_of)) = bi.fin_fy(coalesce(u.period_from, u.as_of)))
   order by (x.status = 'committed') desc, x.as_of desc, x.id desc limit 1;
  if u.kind = 'collection' then
    with s as (select up, sum((v->>'credit')::numeric) credit, sum((v->>'invoice_credit')::numeric) inv_credit, sum((v->>'rows')::int) n, max(v->>'max_date') thru
                 from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'bank'
                       union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'bank') z group by 1),
         bm as (select up, mo, sum(val::numeric) amt from (select 'u' up, m.key mo, m.value #>> '{}' val from jsonb_each(u.controls->'sheets') e(k, v), jsonb_each(v->'by_month') m where v->>'role' = 'bank'
                                                            union all select 'o', m.key, m.value #>> '{}' from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v), jsonb_each(v->'by_month') m where v->>'role' = 'bank') z group by 1, 2),
         bmm as (select mo, max(amt) filter (where up = 'u') a_u, max(amt) filter (where up = 'o') a_o from bm group by mo)
    select jsonb_build_object('kind', 'collection', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'status', u.status, 'receipts_through', (select thru from s where up = 'u'), 'receipts', (select n from s where up = 'u'),
             'credit', (select round(credit) from s where up = 'u'), 'quoting_invoice', (select round(inv_credit) from s where up = 'u'), 'quoting_share', (select round(inv_credit / nullif(credit, 0), 3) from s where up = 'u')),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'status', o.status, 'receipts_through', (select thru from s where up = 'o'), 'receipts', (select n from s where up = 'o'),
             'credit', (select round(credit) from s where up = 'o'), 'quoting_invoice', (select round(inv_credit) from s where up = 'o'), 'quoting_share', (select round(inv_credit / nullif(credit, 0), 3) from s where up = 'o')) end,
           'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'this', round(a_u), 'before', round(a_o), 'change', round(coalesce(a_u, 0) - coalesce(a_o, 0))) order by mo) from bmm)) into cur;
    return cur;
  elsif u.kind = 'sales' then
    with c as (select up, coalesce(sum((v->>'basic')::numeric), 0) basic, coalesce(sum((v->>'rows')::int), 0) n from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'sales'
                 union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'sales') z group by 1),
         bm as (select up, mo, sum((m.value->>'basic')::numeric) basic from (select 'u' up, v from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'sales'
                 union all select 'o', v from jsonb_each(coalesce(o.controls->'sheets', '{}'::jsonb)) e(k, v) where v->>'role' = 'sales') z, jsonb_each(v->'by_month') m(mo, value) group by 1, 2),
         bmm as (select mo, max(basic) filter (where up = 'u') b_u, max(basic) filter (where up = 'o') b_o from bm where mo >= '2024-04' group by mo)
    select jsonb_build_object('kind', 'sales', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status, 'lines', (select n from c where up = 'u'), 'basic', (select round(basic) from c where up = 'u'),
             'months', jsonb_build_array(u.period_from, u.period_to)),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of, 'lines', (select n from c where up = 'o'), 'basic', (select round(basic) from c where up = 'o')) end,
           'by_month', (select jsonb_agg(jsonb_build_object('month', mo, 'this', round(b_u), 'before', round(b_o), 'change', round(coalesce(b_u, 0) - coalesce(b_o, 0))) order by mo) from bmm)) into cur;
    return cur;
  elsif u.kind = 'unadjusted' then
    return jsonb_build_object('kind', 'unadjusted', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status,
             'total', (select round(sum((v->>'credit')::numeric)) from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'unadj'),
             'rows', (select sum((v->>'rows')::int) from jsonb_each(u.controls->'sheets') e(k, v) where v->>'role' = 'unadj')),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of,
             'total', (select round(sum((v->>'credit')::numeric)) from jsonb_each(o.controls->'sheets') e(k, v) where v->>'role' = 'unadj')) end,
           'outstanding_note', 'Unadjusted receipts are money already in the bank; they are never added to cash collected.');
  else
    return jsonb_build_object('kind', 'outstanding', 'this', jsonb_build_object('upload', u.id, 'file', u.file_name, 'as_of', u.as_of, 'status', u.status),
           'compared_with', case when o.id is not null then jsonb_build_object('upload', o.id, 'file', o.file_name, 'as_of', o.as_of) end,
           'note', 'Snapshots are never added together; the latest date is used and older dates stay for history.');
  end if;
end $function$
;

insert into bi.fin_config(key, value, note, updated_at, updated_by) values ('register_months_register_only', 'true'::jsonb, 'wave 119e: billed revenue of register months = the register only', now(), 'wave 119e')
  on conflict (key) do update set value = excluded.value, note = excluded.note, updated_at = now(), updated_by = excluded.updated_by;

select cron.schedule('bi-fin-derive', '*/2 * * * *', $c$set statement_timeout = '170s'; select bi.fin_derive_if_stale()$c$);

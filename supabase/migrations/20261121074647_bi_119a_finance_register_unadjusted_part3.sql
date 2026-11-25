-- Applied to Supabase project via MCP on 20261121074647
create or replace function bi.fin_attr_refresh(p_os bigint default null::bigint, p_co bigint[] default null::bigint[]) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '170s' as $function$
declare v_os bigint := p_os; v_co bigint[] := p_co; v_sr bigint; v_run bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint; v_n int; t0 timestamptz := clock_timestamp();
begin
  if v_os is null then select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1; end if;
  if v_co is null then select coalesce(array_agg(id order by id), '{}') into v_co from bi.fin_upload where kind = 'collection' and status = 'committed'; end if;
  select id into v_sr from bi.fin_upload where kind = 'sales' and status = 'committed' order by as_of desc, id desc limit 1;
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
                            coalesce(ok.im, sk.im, rk.im) im, coalesce(sk.basic, ok.basic, rk.basic, 0) basic,
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
end $function$;

create or replace function bi.fin_billing_basis() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $function$
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
  from b left join sr on true $function$;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '119a');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

select pg_temp.patch('bi.api_collections(date,jsonb)'::regprocedure, array[
  $r$with iv as (select i.inv_month mo, sum(i.basic) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n, sum(i.collected) col, sum(i.gross_l) gl, sum(i.tds_l) tl$r$,
  $r$with iv as (select i.inv_month mo, sum(coalesce(i.traced_basic, i.basic)) basic, sum(i.settled_basic) settled, sum(i.open_basic) open_b, sum(i.inv_n) n, sum(i.collected) col, sum(i.gross_l) gl, sum(i.tds_l) tl,
                     sum(i.basic) billed, sum(coalesce(i.untraced_basic, 0)) untraced, sum(coalesce(i.reg_basic, 0)) reg$r$,
  $r$'invoices', iv.n, 'age_days',$r$,
  $r$'invoices', iv.n, 'billed', round(iv.billed), 'register', case when iv.reg > 0 then round(iv.reg) end, 'status_not_traced', round(iv.untraced), 'age_days',$r$], array[1, 1]);

select pg_temp.patch('bi.call_compute(text,jsonb)'::regprocedure, array[
  $r$      when 'collections' then bi.api_collections(m, f)$r$,
  $r$      when 'collections' then bi.api_collections(m, f)
      when 'fin_sources' then bi.api_fin_sources(f)   -- wave 119a$r$], array[1]);

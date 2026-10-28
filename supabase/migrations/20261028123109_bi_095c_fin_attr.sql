-- Applied to Supabase project via MCP on 20261028123109
-- bi_095c (28-Oct-2026): finance attribution without sharing. Every invoice, receipt and outstanding line is attributed whole to one location and
-- one client (never split by expected revenue): location from the line identity (bi_095b); client = the family's only client at that location, else
-- the client named in the client text (MSME, Car Loan, ...), else the family's largest client there in the last three months. Lines whose location is
-- zone-level or unknown keep that state ("not identified"). Built by bi.fin_attr_refresh(), run at the end of every finance derive.
create table if not exists bi.fin_attr (
  kind text not null, upload_id bigint not null default 0, m date not null, location_id int not null default 0, client_code text not null default '',
  family text not null default '(none)', basis text not null default 'none', client_basis text, amt numeric not null default 0, n int not null default 0, run_id bigint,
  primary key (kind, upload_id, m, location_id, client_code, family, basis));
alter table bi.fin_attr enable row level security;

create or replace function bi.fin_client_word(p text) returns text language sql immutable as $f$
  select case when upper(coalesce(p, '')) ~ 'MSME' then 'MSME' when upper(p) ~ 'INOP' then 'INOP' when upper(p) ~ 'TSR' then 'TSR'
              when upper(p) ~ '\mCAR\M' then 'CAR' when upper(p) ~ '\m(HL|HOME)\M' then 'HL' when upper(p) ~ 'FSL' then 'FSL' when upper(p) ~ '\mITR\M' then 'ITR'
              when upper(p) ~ 'RETAIL' then 'RETAIL' end $f$;
create or replace function bi.fin_client_fits(p_code text, p_word text) returns boolean language sql immutable as $f$
  select case when p_word is null then p_code !~ '_(MSME|INOP|TSR|CAR|HL|FSL|ITR)' else p_code ~ ('_' || p_word) end $f$;

create or replace function bi.fin_attr_refresh(p_os bigint default null, p_co bigint[] default null) returns jsonb
 language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '170s' as $f$
declare v_os bigint := p_os; v_co bigint[] := p_co; v_run bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint; n int; t0 timestamptz := clock_timestamp();
begin
  if v_os is null then select id into v_os from bi.fin_upload where kind = 'outstanding' and status = 'committed' order by as_of desc, id desc limit 1; end if;
  if v_co is null then select coalesce(array_agg(id order by id), '{}') into v_co from bi.fin_upload where kind = 'collection' and status = 'committed'; end if;
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
  k as materialized (select coalesce(ok.inv_key, rk.inv_key) inv_key, coalesce(nullif(ok.loc, 0), rk.loc, 0) loc, coalesce(ok.fam, rk.fam, '(none)') fam, coalesce(ok.cl, rk.cl) cl,
                            coalesce(ok.im, rk.im) im, coalesce(ok.basic, rk.basic, 0) basic, coalesce(ok.src, rk.src, 'none') src
                       from ok full join rk on rk.inv_key = ok.inv_key),
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
  select count(*) into n from ins;
  update bi.fin_attr set amt = 0, n = 0 where run_id is distinct from v_run and (amt <> 0 or n <> 0);
  return jsonb_build_object('rows', n, 'outstanding_upload', v_os, 'collection_uploads', to_jsonb(v_co), 'ms', (extract(epoch from clock_timestamp() - t0) * 1000)::int);
end $f$;

-- run after every finance derive
do $do$
declare d text; o text := $o$  s := jsonb_build_object('run', v_run, 'outstanding_upload', v_os,$o$;
begin
  d := pg_get_functiondef('bi.fin_derive(text)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fin_derive fragment'; end if;
  execute replace(d, o, '  c := coalesce(c, ''{}''::jsonb) || jsonb_build_object(''attribution'', bi.fin_attr_refresh(v_os, v_co));' || chr(10) || o);
end $do$;

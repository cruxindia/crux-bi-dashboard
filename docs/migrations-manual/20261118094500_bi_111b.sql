-- Applied with execute_sql on 18-Nov-2026 15:10 IST after the owner approved it in chat (the approval prompt of the migration tool timed out); recorded in supabase_migrations as 20261118094500 with a pointer to this file.
-- wave 111b (18-Nov-2026): (0) speed of the month-end potential (111a re-ran the month share per row); (1) rate fallback — the 13- and 14-Nov tracker files came without the rate column (revenue was still
-- filled from the last known rate), so business-as-usual in ₹ fell to 0 on the Business tracker and in the BAU model while the branch-
-- manager view showed ₹1.02 cr: both now use the latest known rate on or before the report date. (2) A consistency check that compares
-- the same figure across every API the pages and Ask Crux use, stored daily, shown on Data readiness and read by the consistency agent.
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;

insert into bi.fn_backup (fn, def, wave)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid), 'w111b before' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where (n.nspname = 'bi' and p.proname in ('api_potential', 'api_organic')) or (n.nspname = 'public' and p.proname = 'bi_call');

-- speed: work out the month share once per call (it was re-run for every row: 78 s → 3 s for the zone view)
select pg_temp.patch('bi.api_potential(date,jsonb,text,text)'::regprocedure, array[
  'rem int; share numeric;', 'rem int; share numeric; ms3 jsonb;',
  'rem := greatest(0, bi.workdays(asof + 1, me));', 'rem := greatest(0, bi.workdays(asof + 1, me)); ms3 := bi.month_share3(m, k);',
  'cross join (select bi.month_share3(m, k) ms) msx', 'cross join (select ms3 ms) msx'
], array[1,1,1]);

select pg_temp.patch('bi.api_potential(date,jsonb,text,text)'::regprocedure, array[
  '(select z.rate from bi.zt_row z where z.row_type = ''leaf'' and z.location_id = o.location_id and z.client_code = o.client_code and z.snapshot_date = asof limit 1)',
  '(select z.rate from bi.zt_row z where z.row_type = ''leaf'' and z.location_id = o.location_id and z.client_code = o.client_code and z.snapshot_date <= asof and coalesce(z.rate, 0) > 0 order by z.snapshot_date desc limit 1)'
], array[1]);
select pg_temp.patch('bi.api_organic(date,jsonb,text,text)'::regprocedure, array[
  'and z.snapshot_date <= coalesce(asof, (m + interval ''1 month - 1 day'')::date)',
  'and z.snapshot_date <= coalesce(asof, (m + interval ''1 month - 1 day'')::date) and coalesce(z.rate, 0) > 0   -- wave 111b: latest known rate'
], array[1]);

-- one comparison row: the same figure from every source; ok when they agree (money within ₹2 or 0.05%, counts exactly)
create or replace function bi.cc_row(p_metric text, p_kind text, p_vals jsonb, p_note text default null) returns jsonb language sql immutable as $f$
  with v as (select k, case when jsonb_typeof(x) = 'number' then (x #>> '{}')::numeric end n from jsonb_each(p_vals) e(k, x)),
  s as (select min(n) lo, max(n) hi, count(n) cnt, count(*) - count(n) missing from v)
  select jsonb_build_object('metric', p_metric, 'kind', p_kind, 'note', p_note,
    'values', (select jsonb_object_agg(k, n) from v), 'sources', cnt, 'missing', (select coalesce(jsonb_agg(k), '[]') from v where n is null),
    'low', lo, 'high', hi, 'diff', hi - lo, 'diff_pct', round((hi - lo) / nullif(abs(hi), 0), 4),
    'ok', case when cnt < 2 then null when p_kind = 'money' then (hi - lo) <= greatest(2, abs(hi) * 0.0005) else (hi - lo) <= 0.5 end)
  from s
$f$;

create table if not exists bi.consistency_run (id bigserial primary key, checked_at timestamptz not null default now(), month date not null, result jsonb not null);
revoke all on bi.consistency_run from anon, authenticated;

create or replace function bi.consistency_check(p_month date default null, p_save boolean default true) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare m date := coalesce(p_month, (select max(report_month) from bi.zt_snapshot)); a jsonb; pr jsonb; pc jsonb; pz jsonb; bm jsonb; dr jsonb; pl jsonb; plm jsonb;
        mp jsonb; ov jsonb; orr jsonb; ogc jsonb; un jsonb; sh numeric; r jsonb := '[]'; res jsonb; t0 timestamptz := clock_timestamp(); asof date;
begin
  a := jsonb_build_object('month', m, 'filters', '{}'::jsonb);
  asof := (select max(snapshot_date) from bi.zt_snapshot where report_month = m);
  pr := public.bi_call('potential', a || '{"measure":"revenue","group":"total"}');
  pc := public.bi_call('potential', a || '{"measure":"cases","group":"total"}');
  pz := public.bi_call('potential', a || '{"measure":"revenue","group":"zone"}');
  bm := public.bi_call('bm', a);
  dr := public.bi_call('drill_ops', a || '{"level":"zone","part":"revenue"}');
  pl := public.bi_call('plan', a);
  mp := public.bi_call('market_potential', a);
  ov := public.bi_call('overview', a);
  orr := public.bi_call('organic', a || '{"group":"total","measure":"revenue"}');
  ogc := public.bi_call('organic', a || '{"group":"total","measure":"cases"}');
  un := public.bi_call('branch_units', '{"filters":{},"p":{}}');
  sh := nullif(bm->>'share_of_month_done', '')::numeric;
  select x into plm from jsonb_array_elements(coalesce(pl->'months', '[]')) x where x->>'month' = m::text;
  r := r || bi.cc_row('Business so far (₹)', 'money', jsonb_build_object(
          'Business tracker — month-end potential', pr #> '{rows,0,mtd}', 'Executive overview / branch managers', bm #> '{total,expected_revenue}',
          'Root cause / Management summary', dr #> '{total,mtd}', 'Business-as-usual model', orr #> '{total,actual}'));
  r := r || bi.cc_row('Cases so far', 'count', jsonb_build_object(
          'Executive overview', ov -> 'mtd_cases', 'Branch managers', bm #> '{total,cases}', 'Business tracker — month-end potential (cases)', pc #> '{rows,0,mtd}',
          'Business-as-usual model', ogc #> '{total,actual}'));
  r := r || bi.cc_row('Likely month end (₹)', 'money', jsonb_build_object(
          'Business tracker — month-end potential', pr #> '{rows,0,likely}', 'Root cause / Management summary', dr #> '{total,likely}',
          'Executive overview / branch managers', bm #> '{total,projected_revenue}', 'Planning — this month', plm -> 'outlook',
          'Potential — current business', mp #> '{total,current}', 'Business-as-usual model', orr #> '{total,projected}'));
  r := r || bi.cc_row('Likely month end (cases)', 'count', jsonb_build_object(
          'Executive overview — projection', ov #> '{forecast,curve_projection}', 'Business tracker — month-end potential (cases)', pc #> '{rows,0,likely}',
          'Potential — current business', mp #> '{total,current_cases}', 'Business-as-usual model', ogc #> '{total,projected}'),
          'The overview projection rounds per working day; differences of a few cases are rounding.');
  r := r || bi.cc_row('Zones add up to Pan India — likely month end (₹)', 'money', jsonb_build_object(
          'Pan India', pr #> '{rows,0,likely}', 'Sum of zones', (select to_jsonb(sum((x->>'likely')::numeric)) from jsonb_array_elements(coalesce(pz->'rows', '[]')) x)));
  r := r || bi.cc_row('Business as usual so far (₹)', 'money', jsonb_build_object(
          'Executive overview / branch managers', bm #> '{total,organic_revenue_to_date}', 'Business-as-usual model', orr #> '{total,organic_to_date}',
          'Business tracker (full month × share done)', to_jsonb(round(nullif(pr #>> '{rows,0,organic}', '')::numeric * sh))));
  r := r || bi.cc_row('Business as usual so far (cases)', 'count', jsonb_build_object(
          'Executive overview / branch managers', bm #> '{total,organic_cases_to_date}', 'Business-as-usual model', ogc #> '{total,organic_to_date}'));
  r := r || bi.cc_row('Business as usual — full month (₹)', 'money', jsonb_build_object(
          'Business tracker — month-end potential', pr #> '{rows,0,organic}', 'Business-as-usual model', orr #> '{total,organic_month}',
          'Branch managers (so far ÷ share done)', to_jsonb(round(nullif(bm #>> '{total,organic_revenue_to_date}', '')::numeric / nullif(sh, 0)))));
  r := r || bi.cc_row('Target (₹)', 'money', jsonb_build_object(
          'Business tracker — month-end potential', pr #> '{rows,0,target}', 'Executive overview / branch managers', bm #> '{total,revenue_target}',
          'Root cause / Management summary', dr #> '{total,target}', 'Planning — tracker target', plm -> 'tracker_target'));
  r := r || bi.cc_row('Client branches in the master', 'count', jsonb_build_object(
          'Units by type (Business tracker, Ask Crux)', un #> '{summary,total}', 'Potential (Overview, Root cause, Planning)', mp #> '{total,branches}'),
          'Clients with business in the last three months; administrative offices and website-only lists left out.');
  r := r || bi.cc_row('Active client branches', 'count', jsonb_build_object(
          'Units by type (Business tracker, Ask Crux)', un #> '{summary,active}', 'Potential (Overview, Root cause, Planning)', mp #> '{total,active_branches}'));
  r := r || bi.cc_row('Never-active client branches', 'count', jsonb_build_object(
          'Units by type (Business tracker, Ask Crux)', un #> '{summary,never_active}', 'Potential (Overview, Root cause, Planning)', mp #> '{total,never_branches}'));
  res := jsonb_build_object('month', m, 'as_of', asof, 'checked_at', now(), 'seconds', round(extract(epoch from clock_timestamp() - t0)::numeric, 1),
    'checks', jsonb_array_length(r), 'agree', (select count(*) from jsonb_array_elements(r) x where x->>'ok' = 'true'),
    'differ', (select count(*) from jsonb_array_elements(r) x where x->>'ok' = 'false'),
    'rows', r,
    'method', 'The same figure is read from every page''s data source for Pan India, the latest month and no filters. Money agrees when the sources are within ₹2 or 0.05%; counts must be equal. A difference means two pages would show different numbers for the same thing.');
  if p_save then insert into bi.consistency_run (month, result) values (m, res); end if;
  return res;
end $f$;
revoke all on function bi.consistency_check(date, boolean) from public, anon, authenticated;

create or replace function bi.api_consistency() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  select coalesce((select result || jsonb_build_object('run_id', id) from bi.consistency_run order by id desc limit 1),
                  jsonb_build_object('available', false, 'reason', 'No consistency check has run yet.'))
$f$;

-- served live (not cached) through bi_call
select pg_temp.patch('public.bi_call(text,jsonb)'::regprocedure, array[
  '  if p_fn = ''identity'' then return bi.api_identity(); end if;',
  '  if p_fn = ''identity'' then return bi.api_identity(); end if;
  if p_fn = ''consistency'' then return bi.api_consistency(); end if;   -- wave 111b: latest same-figure-everywhere check'
], array[1]);

-- daily at 08:50, 14:50 and 19:50 IST (after the morning and afternoon uploads and the cache warm)
select cron.unschedule(jobid) from cron.job where jobname = 'bi-consistency-check';
select cron.schedule('bi-consistency-check', '20 3,9,14 * * *', $$select bi.consistency_check()$$);

delete from bi.api_cache where fn in ('potential', 'organic', 'drill_ops', 'market_potential', 'tracker_sheet', 'growth', 'bm');

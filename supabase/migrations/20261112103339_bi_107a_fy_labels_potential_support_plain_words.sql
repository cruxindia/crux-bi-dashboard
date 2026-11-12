-- Applied to Supabase project via MCP on 20261112103339
-- wave 107a (owner 12-Nov-2026 15:53 IST; SOW D316–D319)
-- 1) Quarter labels written out: 'Q3 FY 2026-27 (Oct–Dec 2026)' (Indian FY named in full; FY27 = FY 2026-27, so Q3 = Oct–Dec 2026).
-- 2) Potential and business-as-usual carry their support: clients and branches per source of potential; clients / teams / lines for BAU.
-- 3) Plain words in texts people read: "outlook" -> "likely", "captured" -> "now x% of potential", "headroom" -> "gap to potential".
-- Function bodies are patched in place with exact-text replacements; every replacement is checked (count) so a changed body stops the migration.

create or replace function bi.fy_qname(qs date) returns text language sql immutable as $$
  select 'Q' || (((extract(month from qs)::int - 4 + 12) % 12) / 3 + 1) || ' FY '
         || (extract(year from qs)::int - case when extract(month from qs) < 4 then 1 else 0 end)
         || '-' || to_char((extract(year from qs)::int - case when extract(month from qs) < 4 then 1 else 0 end + 1) % 100, 'FM00') $$;
comment on function bi.fy_qname(date) is 'Indian financial-year quarter written out, e.g. Q3 FY 2026-27 for Oct–Dec 2026 (wave 107, D316).';

create or replace function bi.fy_qlabel(qs date) returns text language sql immutable as $$
  select bi.fy_qname(qs) || ' (' || to_char(qs, 'Mon') || '–' || to_char(qs + interval '2 months', 'Mon YYYY') || ')' $$;

create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $f$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $f$;

create or replace function pg_temp.patch_re(p regprocedure, pat text, rep text, expect int) returns void language plpgsql as $f$
declare d text := pg_get_functiondef(p); n int;
begin
  n := (select count(*) from regexp_matches(d, pat, 'g'));
  if n <> expect then raise exception 'patch_re %: pattern found % times, expected %', p, n, expect; end if;
  execute regexp_replace(d, pat, rep, 'g');
end $f$;

-- 1) quarter labels inside the plan and target-sheet APIs
select pg_temp.patch_re('bi.api_plan(date,jsonb,jsonb)'::regprocedure,
  '''Q'' \|\| \(case when extract\(month from q\.f1\) between 4 and 6 then 1 .*? end\)\s*\|\| '' FY'' \|\| to_char\(case when extract\(month from q\.f1\) >= 4 then q\.f1 \+ interval ''1 year'' else q\.f1 end, ''YY''\)',
  'bi.fy_qname(q.f1)', 1);
select pg_temp.patch_re('bi.api_target_sheet(date,jsonb,jsonb)'::regprocedure,
  '''Q'' \|\| \(case when extract\(month from v_q0\) between 4 and 6 then 1 .*? end\)\s*\|\| '' FY'' \|\| to_char\(case when extract\(month from v_q0\) >= 4 then v_q0 \+ interval ''1 year'' else v_q0 end, ''YY''\)',
  'bi.fy_qname(v_q0)', 1);
select pg_temp.patch('bi.test_growth(date)'::regprocedure, array[
  '''Q1 FY27 (Apr–Jun 2026)''', '''Q1 FY 2026-27 (Apr–Jun 2026)''',
  '''Q3 FY27 (Oct–Dec 2026)''', '''Q3 FY 2026-27 (Oct–Dec 2026)''',
  '''Q4 FY26 (Jan–Mar 2026)''', '''Q4 FY 2025-26 (Jan–Mar 2026)'''], array[1, 1, 1]);

-- 3) plain words in the plan API's method text
select pg_temp.patch('bi.api_plan(date,jsonb,jsonb)'::regprocedure, array[
  '''. Outlook = actual for completed months; for ''', '''. Likely = actual for completed months; for ''',
  'Delta = outlook − plan; shortfall = plan − outlook when positive.', 'Likely − plan = the difference from the plan; shortfall = plan − likely when positive.'], array[1, 1]);
select pg_temp.patch('bi.ask_h_plan(date,jsonb,text)'::regprocedure, array[
  'plan %s, outlook %s (%s actual so far + forecast at current pace)', 'plan %s, likely %s (%s actual so far + expected at the current pace)',
  'plan %s, outlook at current pace %s', 'plan %s, likely at the current pace %s',
  'plan %s, outlook %s → %s %s.', 'plan %s, likely %s → %s %s.',
  '''Outlook %s vs plan %s''', '''Likely %s vs plan %s''',
  '''Outlook'', ''Basis'', ''Delta''', '''Likely'', ''How it is worked out'', ''Likely − plan''',
  '''name'', ''Outlook''', '''name'', ''Likely''',
  '''Plan vs outlook — ''', '''Plan vs likely — '''], array[1, 2, 1, 1, 1, 1, 1]);
select pg_temp.patch('bi.ask_h_potential(date,jsonb,text,text)'::regprocedure, array[
  'current %s (%s captured).%s', 'current %s (now %s of the potential, by value).%s',
  '%s. %s — potential %s, %s captured, opportunity %s', '%s. %s — potential %s, now %s of it, gap %s',
  'against current business of %s — %s captured. The opportunity of %s is:', 'against current business of %s — now %s of the potential, by value. The gap of %s is:',
  '''share of potential captured''', '''current business as a share of potential''',
  'active branch of the same client: headroom, not a forecast.', 'active branch of the same client: a gap to potential, not a forecast.'], array[1, 1, 1, 1, 2]);
select pg_temp.patch('bi.api_targets(date,jsonb,jsonb)'::regprocedure, array[
  'its share of the captured opportunity (share = its opportunity ÷ all opportunity)', 'its share of the gap closed (share = its gap to potential ÷ the whole gap)'], array[1]);

-- 2) potential: clients and branches behind every source, for the total and every breakdown (5 identical aggregate lists)
select pg_temp.patch('bi.api_market_potential(date,jsonb)'::regprocedure, array[
  '''no_team_branches'', coalesce(sum(branches) filter (where layer = ''never_no_team''), 0))',
  '''no_team_branches'', coalesce(sum(branches) filter (where layer = ''never_no_team''), 0), '
  || '''branches'', coalesce(sum(branches) filter (where grp <> ''recover''), 0), '
  || '''never_served_branches'', coalesce(sum(branches) filter (where grp = ''never_served''), 0), '
  || '''extend_team_branches'', coalesce(sum(branches) filter (where grp = ''extend_team''), 0), '
  || '''extend_no_team_branches'', coalesce(sum(branches) filter (where grp = ''extend_no_team''), 0), '
  || '''new_client_branches'', coalesce(sum(branches) filter (where grp = ''new_client''), 0), '
  || '''recover_pairs'', count(*) filter (where grp = ''recover'' and revenue > 0), '
  || '''teams'', count(distinct location_id) filter (where grp = ''current'' and revenue > 0), '
  || '''clients'', count(distinct client_family) filter (where revenue > 0), '
  || '''clients_current'', count(distinct client_family) filter (where grp = ''current'' and revenue > 0), '
  || '''clients_recover'', count(distinct client_family) filter (where grp = ''recover'' and revenue > 0), '
  || '''clients_dormant'', count(distinct client_family) filter (where grp = ''dormant'' and revenue > 0), '
  || '''clients_never_served'', count(distinct client_family) filter (where grp = ''never_served'' and revenue > 0), '
  || '''clients_extend_team'', count(distinct client_family) filter (where grp = ''extend_team'' and revenue > 0), '
  || '''clients_extend_no_team'', count(distinct client_family) filter (where grp = ''extend_no_team'' and revenue > 0), '
  || '''clients_new_client'', count(distinct client_family) filter (where grp = ''new_client'' and revenue > 0))',
  '''Potential = current business + headroom. ',
  '''Potential = current business + the gap to potential. Clients = client families with potential in this selection; branches = active + dormant + never-active branches (back to own best is counted by team × client, not by branch). '], array[5, 1]);

-- 2b) business as usual: clients, teams and team × client lines behind the figure (total and every row)
select pg_temp.patch('bi.api_organic(date,jsonb,text,text)'::regprocedure, array[
  'max(si3) si3' || E'\n' || '         from j group by g)',
  'max(si3) si3, count(distinct client_grp) filter (where org > 0 or actual > 0) n_cl, count(distinct location_id) filter (where org > 0 or actual > 0) n_tm' || E'\n' || '         from j group by g)',
  'max(si_t) si_t, max(si1) si1, max(si2) si2, max(si3) si3, count(*) n from j)',
  'max(si_t) si_t, max(si1) si1, max(si2) si2, max(si3) si3, count(*) n, count(distinct client_grp) filter (where org > 0 or actual > 0) n_cl, count(distinct location_id) filter (where org > 0 or actual > 0) n_tm from j)',
  '(select jsonb_build_object(''actual'', round(actual), ''organic_month'', round(org),',
  '(select jsonb_build_object(''clients'', n_cl, ''teams'', n_tm, ''lines'', n, ''actual'', round(actual), ''organic_month'', round(org),',
  'jsonb_build_object(''group'', g, ''actual'', round(actual),',
  'jsonb_build_object(''group'', g, ''clients'', n_cl, ''teams'', n_tm, ''lines'', n, ''actual'', round(actual),'], array[1, 1, 1, 1]);


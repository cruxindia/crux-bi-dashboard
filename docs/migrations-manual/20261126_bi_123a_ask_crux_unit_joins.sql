-- Wave 123a (26-Nov-2026): Ask Crux's own queries match Force1 cases to client units the way the dashboard does.
-- Owner 26-Nov 18:07 (Ask Crux export "what is the correct comparison", IDBI RACs Oct vs Nov): "Again received wrong output and analysis
-- from Ask Crux. It's the same with other clients too."
-- Checked 26-Nov: valid.
--  1. Ask Crux's SQL joined ai.cases to ai.branches on branch_code as written. Force1 and the branch list write codes differently
--     (8034 / 008034 / prefixes); the dashboard matches on bi.norm_code. For November only 1,540 of 24,897 Force1 cases matched as written
--     against 23,502 normalised (SBI 817 vs 19,033; BOM 23 vs 2,506; IDBI 410 vs 1,408). Five answers used that join
--     (12-Nov SBI Rest of Maharashtra, 13-Nov SBI RACPC TAT, 24-Nov bottom branches, 26-Nov IDBI RAC Oct vs Nov twice).
--  2. ai.branches kept its own copy of the unit-type rule (wave 109a), so it missed wave 122a: 57 IDBI RACs instead of 111.
--  3. The answer compared all of October with 1-24 November and ignored the user's own definition of active.
-- Correct (dashboard method): 111 IDBI RACs; 31 had Force1 cases in October and the same 31 in 1-24 November; 80 neither;
-- cases 1-24 Oct 1,124 vs 1-24 Nov 1,241; full October 1,505.
-- Change: ai.cases and ai.branches get branch_key (= bi.norm_code, the dashboard's match key); ai.branches.unit_type comes from
-- bi.unit_type + bi.unit_type_override (same as bi.api_branch_units, one rule); new view ai.branch_months (Force1 cases per unit and
-- month, with the same-working-day cut-off of the dashboard's month-vs-month comparison); ai_reader may execute the two pure
-- functions bi.norm_code and bi.unit_type (no table access). Answers that used the wrong join are marked disputed (not reused) and
-- their team-memory findings rejected. Undo: restore the two view definitions saved in bi.fn_backup (wave '123a'), drop
-- ai.branch_months, revoke the two grants.

insert into bi.fn_backup(fn, def, wave)
select 'view ai.' || c.relname, pg_get_viewdef(c.oid, true), '123a'
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'ai' and c.relname in ('cases', 'branches');

-- pure functions (no table access): the views below call them as the Ask Crux reader
grant execute on function bi.norm_code(text) to ai_reader;
grant execute on function bi.unit_type(text, text) to ai_reader;

create or replace view ai.cases as
  select cs.case_id, cs.client_code, c.family client_family, cs.branch_code, cs.location_id team_id, cs.status,
         (cs.received_at at time zone 'Asia/Kolkata')::date received_on, (cs.completed_at at time zone 'Asia/Kolkata')::date completed_on,
         (cs.due_at at time zone 'Asia/Kolkata')::date due_on, cs.received_month, cs.points_declared,
         round(extract(epoch from cs.completed_at - cs.received_at) / 3600.0, 1) raw_tat_hours,
         bi.norm_code(cs.branch_code) branch_key
    from bi.case_store cs left join bi.client c on c.code = cs.client_code;
comment on view ai.cases is 'Force1 case records (operations). raw_tat_hours is received to completed without the dashboard''s validity rules; use the operations tool for official TAT. branch_key = the client branch code normalised the dashboard''s way (wave 123a): join to branches on client_family and branch_key, never on branch_code.';

create or replace view ai.branches as
  with pr as (select x.month, array(select jsonb_array_elements_text(coalesce(x.inputs->'inactive_clients', '[]'::jsonb))) inact
                from bi.potential_run x order by x.run_id desc limit 1),
       uni as (select distinct on (b.client_family, b.code_norm) b.client_family, b.code_norm, b.branch_code, b.branch_name, b.city, b.district,
                      b.state, b.pincode, coalesce(b.location_id, fr.location_id) team_id, b.zone_group, b.branch_type
                 from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid cross join pr
                where b.status = 'active' and coalesce(b.verification_status, 'admin_upload') in ('source_verified', 'admin_upload')
                  and coalesce(b.source_type, '') <> 'official_website' and coalesce(b.branch_type, 'branch') <> 'office'
                  and b.code_norm is not null and b.client_family is not null and b.client_family <> all (pr.inact)
                order by b.client_family, b.code_norm, (coalesce(b.location_id, fr.location_id) is null), b.branch_uid)
  select u.client_family, u.branch_code, u.branch_name, u.city, u.district, u.state, u.pincode, u.team_id, l.label team,
         coalesce(l.zone_group, l.rollup_zone, u.zone_group) zone_group, a.first_m first_case_month, a.last_m last_case_month,
         coalesce(a.n, 0) cases_total, coalesce(a.n3, 0) cases_last_3_months,
         case when a.code_norm is null then 'never active' when a.last_m >= (pr.month - interval '2 months')::date then 'active' else 'dormant' end crux_status,
         pr.month status_month,
         coalesce(uo.unit_type, bi.unit_type(u.branch_name, u.branch_type)) unit_type,
         u.code_norm branch_key
    from uni u cross join pr left join bi.branch_activity a on a.fam = u.client_family and a.code_norm = u.code_norm
    left join bi.location l on l.id = u.team_id
    left join bi.unit_type_override uo on uo.client_family = u.client_family and uo.branch_code = u.branch_code;
comment on view ai.branches is 'Client bank branches and units in scope (same universe, status and unit type as the dashboard''s unit counts): active = a case in the last 3 months up to status_month, dormant = cases before that, never active = no case ever. unit_type = bi.unit_type + the client''s own unit lists (wave 123a). branch_key = the match key to cases and branch_months.';

create or replace view ai.branch_months as
  with d as (select max((cs.received_at at time zone 'Asia/Kolkata')::date) f1_to from bi.case_store cs),
       wd as (select g::date dt, date_trunc('month', g)::date m,
                     row_number() over (partition by date_trunc('month', g) order by g) rn
                from d, generate_series(timestamp '2026-01-01', d.f1_to::timestamp, interval '1 day') g
               where extract(isodow from g) <> 7
                 and not exists (select 1 from bi.report_calendar_exception e where e.report_date = g::date and e.active and not e.working_day)),
       n as (select count(*) n from wd, d where wd.m = date_trunc('month', d.f1_to)::date),
       k as (select mm.m as month,
                    coalesce((select w.dt - 1 from wd w where w.m = mm.m and w.rn = n.n + 1),
                             least((mm.m + interval '1 month - 1 day')::date, d.f1_to)) cutoff
               from (select distinct m from wd) mm cross join n cross join d),
       c as (select coalesce(cl.family, cs.client_code) client_family, bi.norm_code(cs.branch_code) branch_key, cs.received_month as month,
                    (cs.received_at at time zone 'Asia/Kolkata')::date rd
               from bi.case_store cs left join bi.client cl on cl.code = cs.client_code)
  select c.client_family, c.branch_key, c.month, count(*) cases, count(*) filter (where c.rd <= k.cutoff) cases_to_same_working_day,
         k.cutoff same_working_day_to, d.f1_to force1_data_to
    from c join k on k.month = c.month cross join d
   where c.branch_key is not null
   group by c.client_family, c.branch_key, c.month, k.cutoff, d.f1_to;
comment on view ai.branch_months is 'wave 123a: Force1 cases per client unit (client_family + branch_key) and month since Jan-2026. cases = the whole month (the open month only to force1_data_to); cases_to_same_working_day = cases from the 1st to same_working_day_to, the day with as many working days (Mon-Sat less report holidays) as the open month has up to force1_data_to, the dashboard''s month-vs-month basis. Units with no case in a month have no row: start from branches and LEFT JOIN.';
grant select on ai.cases, ai.branches, ai.branch_months to ai_reader;

-- answers built on the code-as-written join: not reused, and their team-memory findings retired
with s as (select m.id, lower(x.s->'args'->>'query') q
             from bi.ai_message m cross join lateral jsonb_array_elements(m.trace->'steps') x(s)
            where x.s->>'tool' = 'run_sql' and coalesce((x.s->>'ok')::boolean, false)),
bad as (select distinct id from s
         where q ~ '\mbranches\M' and q ~ '\mcases\M'
           and (q ~ '[a-z_]+\.branch_code\s*=\s*[a-z_]+\.branch_code' or q ~ 'using\s*\([^)]*branch_code' or q ~ 'branch_code\s+in\s*\(\s*select\s+[a-z_.]*branch_code')),
u as (update bi.ai_message m set status = 'disputed',
             correction = concat_ws(' ', nullif(m.correction, ''), 'Wave 123a: this answer matched Force1 cases to client branches by the code as written, so most cases were missed; ask again for the corrected figures.')
        where m.id in (select id from bad) returning m.id)
update bi.agent_memory am set status = 'rejected'
 where am.status in ('open', 'confirmed') and (am.evidence->>'message_id') ~ '^\d+$' and (am.evidence->>'message_id')::bigint in (select id from bad);

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('wave-123a', 'ask_crux_views', 'ai.branches', 'branch_key', jsonb_build_object('change', 'Ask Crux views: branch_key join, dashboard unit types, ai.branch_months; wrong-join answers disputed', 'request', 'owner 26-Nov 18:07'));

-- 26-Nov 17:53: "active RAC = RAC which gave business in Nov-2026" was answered with the dashboard's 3-month status (35), not the user's definition (31)
update bi.ai_message set status = 'disputed',
       correction = concat_ws(' ', nullif(correction, ''), 'Wave 123a: active was defined by the user as business in Nov-2026; the answer used the dashboard''s 3-month status. 31 of 111 IDBI RACs had Force1 cases in 1-24 Nov.')
 where id = 1343 and question ilike '%active rac are rac which have given business%';
update bi.agent_memory set status = 'rejected'
 where status in ('open', 'confirmed') and evidence->>'message_id' = '1343';

-- check as the Ask Crux reader (rolls the whole change back if the views cannot be read or disagree with the dashboard count)
do $t$ declare r jsonb; v_view int; v_dash int; v_m jsonb;
begin
  r := ai.run_select('select count(*) n from branches where client_family = ''IDBI'' and unit_type = ''RAC''', 5);
  v_view := (r->'rows'->0->>'n')::int;
  v_dash := (bi.api_branch_units('{"client_family":"IDBI"}'::jsonb, '{"unit_type":"RAC"}'::jsonb)->'summary'->>'total')::int;
  if v_view is distinct from v_dash then raise exception '123a: IDBI RAC count view % vs dashboard %', v_view, v_dash; end if;
  v_m := ai.run_select('select count(*) n from cases c join branches b on b.client_family = c.client_family and b.branch_key = c.branch_key where c.received_month = date ''2026-11-01''', 5);
  if coalesce((v_m->'rows'->0->>'n')::int, 0) = 0 then raise exception '123a: no November case matched through branch_key'; end if;
  v_m := ai.run_select('select sum(cases) n from branch_months where month = date ''2026-11-01''', 5);
  if coalesce((v_m->'rows'->0->>'n')::int, 0) = 0 then raise exception '123a: branch_months empty for November'; end if;
  raise notice '123a ok: IDBI RAC % (dashboard %)', v_view, v_dash;
end $t$;

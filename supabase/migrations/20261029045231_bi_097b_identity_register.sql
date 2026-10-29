-- Applied to Supabase project via MCP on 20261029045231
-- bi_097b (29-Oct-2026): canonical identity, part 2 — one identity register across the sources and its known-example acceptance test.
-- bi.case_locate_detail: the rule-book result per case plus the candidate location from each kind of evidence (to find conflicting evidence).
-- bi.identity_audit_run: measures every source (tracker, Case Wise, Point Wise, invoices, receipts, outstanding, client identifiers, branch master):
--   raw label kept, canonical id present, basis, unresolved and ambiguous records; keeps capped exception lists per issue.
do $do$
declare d text;
begin
  d := pg_get_functiondef('bi.case_locate(bigint[])'::regprocedure);
  if position('FUNCTION bi.case_locate(' in d) = 0 or position('RETURNS TABLE(case_id bigint, location_id integer, place text, basis text)' in d) = 0
     or position($o$else 'not identified' end
    from r$o$ in d) = 0 then raise exception 'case_locate fragments not found'; end if;
  d := replace(d, 'FUNCTION bi.case_locate(', 'FUNCTION bi.case_locate_detail(');
  d := replace(d, 'RETURNS TABLE(case_id bigint, location_id integer, place text, basis text)',
                  'RETURNS TABLE(case_id bigint, location_id integer, place text, basis text, l_area_office integer, l_branch_name integer, l_customers integer, l_pincode integer)');
  d := replace(d, $o$else 'not identified' end
    from r$o$, $n$else 'not identified' end,
         l1.l, l3.l, l4.l, l7.l
    from r$n$);
  execute d;
end $do$;

create table if not exists bi.identity_run (id bigserial primary key, started_at timestamptz not null default now(), finished_at timestamptz, status text not null, summary jsonb, errors text);
create table if not exists bi.identity_exception (run_id bigint not null references bi.identity_run(id), source text not null, issue text not null, record_key text, detail jsonb);
create index if not exists identity_exception_run on bi.identity_exception (run_id, source, issue);
alter table bi.identity_run enable row level security;
alter table bi.identity_exception enable row level security;

create or replace function bi.identity_audit_run(p_cap int default 300) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare v_run bigint; s jsonb := '{}'::jsonb; x jsonb;
begin
  insert into bi.identity_run(status) values ('running') returning id into v_run;
  -- Case Wise
  with dd as materialized (
         select d.*, cs.location_id cur, cs.client_code, cs.area_office_id, cs.branch_id, cs.recon_unit
           from bi.case_locate_detail(null) d join bi.case_store cs on cs.case_id = d.case_id),
       iss as (
         select 'not identified' issue, dd.* from dd where dd.location_id is null
         union all select 'stored location differs from the rules', dd.* from dd where dd.cur is distinct from dd.location_id
         union all select 'area office and branch name point to different locations', dd.* from dd
          where dd.l_area_office is not null and dd.l_branch_name is not null and dd.l_area_office <> dd.l_branch_name),
       ins as (
         insert into bi.identity_exception(run_id, source, issue, record_key, detail)
         select v_run, 'case', z.issue, z.case_id::text, jsonb_build_object('client', z.client_code, 'unit', z.recon_unit,
                'area_office', (select val from bi.dim where id = z.area_office_id), 'branch', (select val from bi.dim where id = z.branch_id),
                'stored', (select label from bi.location where id = z.cur), 'rules', (select label from bi.location where id = z.location_id), 'basis', z.basis, 'place', z.place,
                'by_area_office', (select label from bi.location where id = z.l_area_office), 'by_branch_name', (select label from bi.location where id = z.l_branch_name))
           from (select iss.*, row_number() over (partition by iss.issue order by iss.case_id desc) rn from iss) z where z.rn <= p_cap
         returning 1)
  select jsonb_build_object('rows', count(*), 'raw_kept', 'area office, branch name, branch code, client code, file group (as received)',
           'canonical', count(*) filter (where location_id is not null), 'not_identified', count(*) filter (where location_id is null),
           'stored_differs_from_rules', count(*) filter (where cur is distinct from location_id),
           'ambiguous_area_office_vs_branch', count(*) filter (where l_area_office is not null and l_branch_name is not null and l_area_office <> l_branch_name),
           'basis', (select jsonb_object_agg(b, n) from (select basis b, count(*) n from dd group by 1) q),
           'sum_by_location_equals_rows', (select sum(n) from (select location_id, count(*) n from dd group by 1) q) = count(*),
           'exceptions_kept', (select count(*) from ins))
    into x from dd;
  s := s || jsonb_build_object('case', x);
  -- Point Wise
  with p as materialized (
         select ps.point_id, ps.case_id, (c.case_id is not null) has_case, ps.recon_unit pu, c.recon_unit cu, c.location_id cloc, pl.location_id plloc, pl.basis, pl.reason, (pl.point_id is not null) exc
           from bi.point_store ps left join bi.case_store c on c.case_id = ps.case_id left join bi.point_loc pl on pl.point_id = ps.point_id and pl.active),
       ins as (
         insert into bi.identity_exception(run_id, source, issue, record_key, detail)
         select v_run, 'point', z.issue, z.point_id::text, jsonb_build_object('case', z.case_id, 'unit', z.pu, 'case_unit', z.cu, 'basis', z.basis, 'reason', z.reason,
                'case_location', (select label from bi.location where id = z.cloc), 'point_location', (select label from bi.location where id = z.plloc))
           from (select q.*, row_number() over (partition by q.issue order by q.point_id desc) rn from (
                   select 'not identified' issue, p.* from p where (p.exc and p.plloc is null) or (not p.exc and p.cloc is null)
                   union all select 'placed on its own evidence (no case or a different branch)', p.* from p where p.exc and p.plloc is not null
                   union all select 'point file unit differs from its case unit', p.* from p where p.has_case and p.pu is distinct from p.cu) q) z where z.rn <= p_cap
         returning 1)
  select jsonb_build_object('rows', count(*), 'raw_kept', 'branch name, client code, pincode, file group (as received)',
           'follows_its_case', count(*) filter (where not exc and cloc is not null),
           'own_evidence', count(*) filter (where exc and plloc is not null),
           'not_identified', count(*) filter (where (exc and plloc is null) or (not exc and cloc is null)),
           'no_matching_case', count(*) filter (where not has_case),
           'unit_differs_from_case', count(*) filter (where has_case and pu is distinct from cu),
           'basis', (select jsonb_object_agg(coalesce(basis, 'its case'), n) from (select basis, count(*) n from p group by 1) q),
           'exceptions_kept', (select count(*) from ins))
    into x from p;
  s := s || jsonb_build_object('point', x);
  -- Zonal Tracker (leaf rows: one location × client per report date)
  with z as materialized (select snapshot_date, location_id, client_code, location_label, client_label from bi.zt_row where row_type = 'leaf'),
       lat as (select max(snapshot_date) d from bi.zt_snapshot),
       ins as (
         insert into bi.identity_exception(run_id, source, issue, record_key, detail)
         select v_run, 'tracker', 'label mapping needs review', a.alias, jsonb_build_object('location', l.label, 'method', a.method, 'confidence', a.confidence, 'evidence', a.evidence)
           from bi.location_alias a left join bi.location l on l.id = a.location_id where a.source = 'zonal_label' and a.review_status = 'needs_review'
         union all
         select v_run, 'tracker', 'leaf row without a location or client', q.snapshot_date || ' ' || coalesce(q.location_label, '') || ' / ' || coalesce(q.client_label, ''), null
           from (select z.*, row_number() over (order by z.snapshot_date desc) rn from z where z.location_id is null or z.client_code is null) q where q.rn <= p_cap
         returning 1)
  select jsonb_build_object('rows', count(*), 'raw_kept', 'location label, client label, zone label (as received)',
           'canonical', count(*) filter (where location_id is not null and client_code is not null),
           'no_location', count(*) filter (where location_id is null), 'no_client', count(*) filter (where client_code is null),
           'latest_snapshot', (select d from lat), 'latest_rows', count(*) filter (where snapshot_date = (select d from lat)),
           'latest_unmapped', count(*) filter (where snapshot_date = (select d from lat) and (location_id is null or client_code is null)),
           'labels_needing_review', (select count(*) from bi.location_alias where source = 'zonal_label' and review_status = 'needs_review'),
           'locations_without_zone', (select count(*) from bi.location l where l.zone_group is null and not coalesce(l.is_rollup, false)
                                        and exists (select 1 from bi.zt_row r where r.location_id = l.id and r.snapshot_date >= (select d from lat) - 31)),
           'exceptions_kept', (select count(*) from ins))
    into x from z;
  s := s || jsonb_build_object('tracker', x);
  -- Finance (whole lines; invoices, receipts, outstanding)
  select jsonb_object_agg(kind, j) into x from (
    select kind, jsonb_build_object('lines', sum(n), 'amount', round(sum(amt), 2), 'with_location', round(sum(amt) filter (where location_id is not null), 2),
             'without_location', round(coalesce(sum(amt) filter (where location_id is null), 0), 2), 'without_client', round(coalesce(sum(amt) filter (where client_code is null and family is null), 0), 2),
             'location_share', round(sum(amt) filter (where location_id is not null) / nullif(sum(amt), 0), 4),
             'basis', (select jsonb_object_agg(coalesce(b2.basis, 'none'), b2.a) from (select basis, round(sum(amt), 2) a from bi.fin_attr f2 where f2.kind = f.kind group by 1) b2)) j
      from bi.fin_attr f group by kind) q;
  insert into bi.identity_exception(run_id, source, issue, record_key, detail)
  select v_run, 'finance', 'line not tied to a location (open review item)', r.key, jsonb_build_object('title', r.title, 'amount', r.amount, 'lines', r.n)
    from bi.fin_review r where r.status = 'open' and r.kind = 'map_location' limit p_cap;
  s := s || jsonb_build_object('finance', coalesce(x, '{}'::jsonb) || jsonb_build_object('raw_kept', 'sheet, row, row label, invoice number, client text, payer branch code / IFSC and name (narration never stored)'));
  -- Client identifiers
  select jsonb_build_object('aliases', (select jsonb_object_agg(source || ' ' || review_status, n) from (select source, review_status, count(*) n from bi.client_alias group by 1, 2) q),
           'tracker_rows_without_client', (select count(*) from bi.zt_row where row_type = 'leaf' and client_code is null),
           'cases_with_unknown_client', (select count(*) from bi.case_store c where c.client_code is null or not exists (select 1 from bi.client k where k.code = c.client_code)),
           'finance_text_map', (select count(*) from bi.fin_client_map),
           'name_aliases', (select count(*) from bi.client_name_alias)) into x;
  s := s || jsonb_build_object('client', x);
  -- Branch master
  select jsonb_build_object('rows', count(*), 'with_branch_code', count(*) filter (where code_norm is not null and code_norm <> ''),
           'with_location', count(*) filter (where location_id is not null), 'without_location', count(*) filter (where location_id is null),
           'by_source_type', (select jsonb_object_agg(coalesce(source_type, '?'), n) from (select source_type, count(*) n from bi.client_branch_master group by 1) q),
           'by_status', (select jsonb_object_agg(coalesce(verification_status, '?'), n) from (select verification_status, count(*) n from bi.client_branch_master group by 1) q),
           'raw_kept', 'source name, IFSC / code, address, district, pincode, source URL and version')
    into x from bi.client_branch_master;
  s := s || jsonb_build_object('branch_master', x);
  update bi.identity_run set finished_at = now(), status = 'succeeded', summary = s where id = v_run;
  return jsonb_build_object('run', v_run) || s;
exception when others then
  update bi.identity_run set finished_at = now(), status = 'failed', errors = sqlerrm where id = v_run;
  return jsonb_build_object('run', v_run, 'error', sqlerrm);
end $f$;

create or replace function bi.api_identity() returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  select coalesce((select jsonb_build_object('available', true, 'run', r.id, 'started_at', r.started_at, 'finished_at', r.finished_at, 'summary', r.summary,
            'issues', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'issue', issue, 'kept', n) order by source, issue), '[]') from (select source, issue, count(*) n from bi.identity_exception e where e.run_id = r.id group by 1, 2) q),
            'method', 'Each source keeps its raw labels. Canonical location / client = the documented rule order for that source (tracker label aliases; Case Wise rule book; Point Wise follows its case only when the case exists and the branch agrees, else its own evidence; finance invoice series → row label → sheet, receipts through the invoice they settle, then the paying bank branch). Exceptions are capped per issue; the counts are complete.')
     from bi.identity_run r where r.status = 'succeeded' order by r.id desc limit 1), jsonb_build_object('available', false)) $f$;

create or replace function bi.identity_exceptions(p jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public' as $f$
  select jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('source', e.source, 'issue', e.issue, 'record', e.record_key, 'detail', e.detail))
           from bi.identity_exception e where e.run_id = (select max(id) from bi.identity_run where status = 'succeeded')
            and (nullif(p->>'source', '') is null or e.source = p->>'source') and (nullif(p->>'issue', '') is null or e.issue = p->>'issue')), '[]')) $f$;

do $do$
declare d text; o text := $o$  select v into r from bi.api_cache where k = v_key and version = v_ver;$o$;
begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_call fragment'; end if;
  execute replace(d, o, $n$  if p_fn = 'identity' then return bi.api_identity(); end if;   -- latest identity run; not cached (runs do not change the data version)$n$ || chr(10) || o);
  d := pg_get_functiondef('public.bi_admin(text,jsonb)'::regprocedure);
  o := $o$    when 'person_role' then return bi.person_role_admin('admin-key:'||coalesce(nullif(trim(p->>'editor'),''),'unnamed'), p - 'admin_key');$o$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_admin fragment'; end if;
  execute replace(d, o, o || chr(10) || $n$    when 'identity_exceptions' then return bi.identity_exceptions(p - 'admin_key');$n$);
end $do$;

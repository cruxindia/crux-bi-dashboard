-- Applied to Supabase project via MCP on 20261021072259
-- bi_089c (21-Oct-2026): Ask Crux v3 (AUDIT_REGISTER A3) — grounded, structured, context-aware answers (part 1: helpers)
create or replace function bi.ask_act(p_priority text, p_action text, p_reason text, p_owner text, p_benefit text) returns jsonb language sql immutable as
$f$ select jsonb_build_object('priority', p_priority, 'action', p_action, 'reason', p_reason, 'owner_level', p_owner, 'expected_benefit', coalesce(p_benefit, 'Not quantified')) $f$;

create or replace function bi.ask_tat_stats(p_months date[], f jsonb, grp text) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with fe as (select (coalesce(f, '{}'::jsonb) - 'client_family') = '{}'::jsonb nofilter),
lok as (select l.id from bi.location l where bi.loc_ok(l.id, l.recon_unit, f)),
uok as (select distinct l.recon_unit u from bi.location l where l.recon_unit is not null and bi.loc_ok(null, l.recon_unit, f)),
fok as (select code from bi.client where bi.fam_ok(code, f)),
dr as (select (select start_field from bi.tat_rule where measure = 'document') s, (select end_field from bi.tat_rule where measure = 'document') e,
              coalesce((select back_entry_minutes from bi.tat_rule where measure = 'case'), 15) be),
c as (select z.m, z.k, count(*) n, round(avg(z.h)::numeric, 1) avg,
             round(percentile_cont(0.5) within group (order by z.h)::numeric, 1) median,
             round(percentile_cont(0.9) within group (order by z.h)::numeric, 1) p90,
             count(*) filter (where z.h * 60 < (select be from dr)) back_entered, grouping(z.m, z.k) g
      from (select s.received_month m, case grp when 'client' then cl.family when 'location' then s.location_id::text else s.recon_unit end k, s.h
            from (select s.*, bi.tat_hours(s.received_at, s.completed_at) h from bi.case_store s
                  where s.received_month = any(p_months) and s.received_at >= '2024-03-31 18:30:00+00' and upper(s.status) = 'COMPLETED' and s.completed_at >= s.received_at) s
            left join bi.client cl on cl.code = s.client_code
            where ((select nofilter from fe) or s.location_id in (select id from lok) or (s.location_id is null and s.recon_unit in (select u from uok)))
              and (f->>'client_family' is null or cl.family = f->>'client_family')) z
      group by grouping sets ((z.m, z.k), (z.m))),
p as (select q.m, q.k, count(fh) field_n, round(percentile_cont(0.5) within group (order by fh)::numeric, 1) field_median,
             round(percentile_cont(0.9) within group (order by fh)::numeric, 1) field_p90,
             count(dh) doc_n, round(percentile_cont(0.5) within group (order by dh)::numeric, 1) doc_median,
             round(percentile_cont(0.9) within group (order by dh)::numeric, 1) doc_p90, grouping(q.m, q.k) g
      from (select p.created_month m,
                   case grp when 'client' then cl.family when 'location' then cs.location_id::text else coalesce(cs.recon_unit, p.recon_unit) end k,
                   case when t.category = 'field' and p.field_reviewed_at < p.assigned_at + interval '120 days' then bi.tat_hours(p.assigned_at, p.field_reviewed_at) end fh,
                   case when t.category = 'document' then bi.tat_hours(
                          case (select s from dr) when 'assigned_at' then p.assigned_at when 'assigned_at_else_created_at' then coalesce(p.assigned_at, p.created_at) else p.created_at end,
                          case (select e from dr) when 'field_reviewed_at' then p.field_reviewed_at else p.completed_at end) end dh
            from bi.point_store p join bi.dim d on d.id = p.point_type_id join bi.point_type t on t.name = d.val
            left join bi.case_store cs on cs.case_id = p.case_id
            left join bi.client cl on cl.code = coalesce(cs.client_code, p.client_code_raw)
            where p.created_month = any(p_months) and p.created_at >= '2024-03-31 18:30:00+00' and t.category in ('field', 'document')
              and ((select nofilter from fe) or cs.location_id in (select id from lok) or (cs.location_id is null and coalesce(cs.recon_unit, p.recon_unit) in (select u from uok)))
              and (f->>'client_family' is null or coalesce(cs.client_code, p.client_code_raw) in (select code from fok))) q
      group by grouping sets ((q.m, q.k), (q.m))),
c2 as (select c.*, case when g = 1 then '~total' else k end kk from c),
p2 as (select p.*, case when g = 1 then '~total' else k end kk from p)
select coalesce(jsonb_agg(jsonb_build_object('month', coalesce(c.m, p.m), 'key', coalesce(c.kk, p.kk),
   'label', case when coalesce(c.kk, p.kk) = '~total' then 'Total' when grp = 'location' then (select label from bi.location where id::text = coalesce(c.kk, p.kk)) else coalesce(c.kk, p.kk) end,
   'case_n', coalesce(c.n, 0), 'case_avg', c.avg, 'case_median', c.median, 'case_p90', c.p90, 'case_back_entered', coalesce(c.back_entered, 0),
   'field_n', coalesce(p.field_n, 0), 'field_median', p.field_median, 'field_p90', p.field_p90,
   'doc_n', coalesce(p.doc_n, 0), 'doc_median', p.doc_median, 'doc_p90', p.doc_p90)), '[]'::jsonb)
from c2 c full join p2 p on p.m = c.m and p.kk is not distinct from c.kk
$function$;

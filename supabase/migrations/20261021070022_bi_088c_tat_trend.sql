-- Applied to Supabase project via MCP on 20261021070022
create or replace function bi.tat_trend(f jsonb, p_months int default 12) returns jsonb
language sql stable security definer set search_path to 'bi', 'public' as $function$
with mm as (select generate_series(date_trunc('month', (select max(received_month) from bi.case_store)) - make_interval(months => greatest(least(p_months, 24), 2) - 1),
                                   (select max(received_month) from bi.case_store), interval '1 month')::date m),
fe as (select (coalesce(f, '{}'::jsonb) - 'client_family') = '{}'::jsonb nofilter),
lok as (select l.id from bi.location l where bi.loc_ok(l.id, l.recon_unit, f)),
uok as (select distinct l.recon_unit u from bi.location l where l.recon_unit is not null and bi.loc_ok(null, l.recon_unit, f)),
fok as (select code from bi.client where bi.fam_ok(code, f)),
dr as (select (select start_field from bi.tat_rule where measure = 'document') s, (select end_field from bi.tat_rule where measure = 'document') e),
c as (select s.received_month m, count(*) n,
             round(avg(h)::numeric, 1) avg,
             round(percentile_cont(0.5) within group (order by h)::numeric, 1) median,
             round(percentile_cont(0.9) within group (order by h)::numeric, 1) p90
      from (select s.received_month, bi.tat_hours(s.received_at, s.completed_at) h
            from bi.case_store s left join bi.client cl on cl.code = s.client_code
            where s.received_month in (select m from mm) and s.received_at >= '2024-03-31 18:30:00+00' and upper(s.status) = 'COMPLETED'
              and s.completed_at >= s.received_at
              and ((select nofilter from fe) or s.location_id in (select id from lok) or (s.location_id is null and s.recon_unit in (select u from uok)))
              and (f->>'client_family' is null or cl.family = f->>'client_family')) s
      group by 1),
p as (select q.m, count(fh) field_n, round(avg(fh)::numeric, 1) field_avg,
             round(percentile_cont(0.5) within group (order by fh)::numeric, 1) field_median,
             round(percentile_cont(0.9) within group (order by fh)::numeric, 1) field_p90,
             count(dh) doc_n, round(avg(dh)::numeric, 1) doc_avg,
             round(percentile_cont(0.5) within group (order by dh)::numeric, 1) doc_median,
             round(percentile_cont(0.9) within group (order by dh)::numeric, 1) doc_p90
      from (select p.created_month m,
                   case when t.category = 'field' and p.field_reviewed_at < p.assigned_at + interval '120 days' then bi.tat_hours(p.assigned_at, p.field_reviewed_at) end fh,
                   case when t.category = 'document' then bi.tat_hours(
                          case (select s from dr) when 'assigned_at' then p.assigned_at when 'assigned_at_else_created_at' then coalesce(p.assigned_at, p.created_at) else p.created_at end,
                          case (select e from dr) when 'field_reviewed_at' then p.field_reviewed_at else p.completed_at end) end dh
            from bi.point_store p join bi.dim d on d.id = p.point_type_id join bi.point_type t on t.name = d.val
            left join bi.case_store cs on cs.case_id = p.case_id
            where p.created_month in (select m from mm) and p.created_at >= '2024-03-31 18:30:00+00' and t.category in ('field', 'document')
              and ((select nofilter from fe) or cs.location_id in (select id from lok) or (cs.location_id is null and coalesce(cs.recon_unit, p.recon_unit) in (select u from uok)))
              and (f->>'client_family' is null or coalesce(cs.client_code, p.client_code_raw) in (select code from fok))) q
      group by 1)
select coalesce(jsonb_agg(jsonb_build_object('month', mm.m,
   'case', jsonb_build_object('n', coalesce(c.n, 0), 'avg', c.avg, 'median', c.median, 'p90', c.p90),
   'field', jsonb_build_object('n', coalesce(p.field_n, 0), 'avg', p.field_avg, 'median', p.field_median, 'p90', p.field_p90),
   'document', jsonb_build_object('n', coalesce(p.doc_n, 0), 'avg', p.doc_avg, 'median', p.doc_median, 'p90', p.doc_p90)) order by mm.m), '[]'::jsonb)
from mm left join c on c.m = mm.m left join p on p.m = mm.m
$function$;

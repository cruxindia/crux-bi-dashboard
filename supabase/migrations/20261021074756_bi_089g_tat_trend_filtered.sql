-- Applied to Supabase project via MCP on 20261021074756
create or replace function bi.tat_trend(f jsonb, p_months int default 12) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $function$
declare mm date[]; nofilter boolean := (coalesce(f, '{}'::jsonb) - 'client_family') = '{}'::jsonb; fam text := f->>'client_family';
        ds text := (select start_field from bi.tat_rule where measure = 'document'); de text := (select end_field from bi.tat_rule where measure = 'document');
        c jsonb; p jsonb; mx date := (select max(received_month) from bi.case_store);
        lok int[] := (select array_agg(l.id) from bi.location l where bi.loc_ok(l.id, l.recon_unit, f));
        uok text[] := (select array_agg(distinct l.recon_unit) from bi.location l where l.recon_unit is not null and bi.loc_ok(null, l.recon_unit, f));
        fcodes text[] := (select array_agg(code) from bi.client where family = f->>'client_family');
begin
  select array_agg(g::date order by g) into mm from generate_series(date_trunc('month', mx) - make_interval(months => greatest(least(p_months, 24), 2) - 1), mx, interval '1 month') g;
  select coalesce(jsonb_object_agg(m, jsonb_build_object('n', n, 'avg', avg, 'median', median, 'p90', p90)), '{}') into c from (
    select s.received_month m, count(*) n, round(avg(h)::numeric, 1) avg,
           round(percentile_cont(0.5) within group (order by h)::numeric, 1) median, round(percentile_cont(0.9) within group (order by h)::numeric, 1) p90
    from (select s.received_month, s.location_id, s.recon_unit, s.client_code, bi.tat_hours(s.received_at, s.completed_at) h from bi.case_store s
          where s.received_month = any(mm) and s.received_at >= '2024-03-31 18:30:00+00' and upper(s.status) = 'COMPLETED' and s.completed_at >= s.received_at) s
    left join bi.client cl on cl.code = s.client_code
    where (nofilter or s.location_id in (select l.id from bi.location l where bi.loc_ok(l.id, l.recon_unit, f))
                    or (s.location_id is null and s.recon_unit in (select l.recon_unit from bi.location l where l.recon_unit is not null and bi.loc_ok(null, l.recon_unit, f))))
      and (fam is null or cl.family = fam)
    group by 1) x;
  if nofilter and fam is null then
    select coalesce(jsonb_object_agg(m, j), '{}') into p from (
      select q.m, jsonb_build_object('field_n', count(fh), 'field_avg', round(avg(fh)::numeric, 1), 'field_median', round(percentile_cont(0.5) within group (order by fh)::numeric, 1),
               'field_p90', round(percentile_cont(0.9) within group (order by fh)::numeric, 1), 'doc_n', count(dh), 'doc_avg', round(avg(dh)::numeric, 1),
               'doc_median', round(percentile_cont(0.5) within group (order by dh)::numeric, 1), 'doc_p90', round(percentile_cont(0.9) within group (order by dh)::numeric, 1)) j
      from (select p.created_month m,
                   case when t.category = 'field' and p.field_reviewed_at < p.assigned_at + interval '120 days' then bi.tat_hours(p.assigned_at, p.field_reviewed_at) end fh,
                   case when t.category = 'document' then bi.tat_hours(
                          case ds when 'assigned_at' then p.assigned_at when 'assigned_at_else_created_at' then coalesce(p.assigned_at, p.created_at) else p.created_at end,
                          case de when 'field_reviewed_at' then p.field_reviewed_at else p.completed_at end) end dh
            from bi.point_store p join bi.dim d on d.id = p.point_type_id join bi.point_type t on t.name = d.val
            where p.created_month = any(mm) and p.created_at >= '2024-03-31 18:30:00+00' and t.category in ('field', 'document')) q
      group by q.m) x;
  else
    select coalesce(jsonb_object_agg(m, j), '{}') into p from (
      select q.m, jsonb_build_object('field_n', count(fh), 'field_avg', round(avg(fh)::numeric, 1), 'field_median', round(percentile_cont(0.5) within group (order by fh)::numeric, 1),
               'field_p90', round(percentile_cont(0.9) within group (order by fh)::numeric, 1), 'doc_n', count(dh), 'doc_avg', round(avg(dh)::numeric, 1),
               'doc_median', round(percentile_cont(0.5) within group (order by dh)::numeric, 1), 'doc_p90', round(percentile_cont(0.9) within group (order by dh)::numeric, 1)) j
      from (select p.created_month m,
                   case when t.category = 'field' and p.field_reviewed_at < p.assigned_at + interval '120 days' then bi.tat_hours(p.assigned_at, p.field_reviewed_at) end fh,
                   case when t.category = 'document' then bi.tat_hours(
                          case ds when 'assigned_at' then p.assigned_at when 'assigned_at_else_created_at' then coalesce(p.assigned_at, p.created_at) else p.created_at end,
                          case de when 'field_reviewed_at' then p.field_reviewed_at else p.completed_at end) end dh
            from (select p.*, cs.client_code cc from bi.case_store cs join bi.point_store p on p.case_id = cs.case_id
                   where (nofilter or cs.location_id = any(lok) or (cs.location_id is null and cs.recon_unit = any(uok)))
                     and (fam is null or cs.client_code = any(fcodes)) and p.created_month = any(mm)
                  union all
                  select p.*, p.client_code_raw from bi.point_store p
                   where p.created_month = any(mm) and (nofilter or p.recon_unit = any(uok)) and (fam is null or p.client_code_raw = any(fcodes))
                     and not exists (select 1 from bi.case_store c where c.case_id = p.case_id)) p
            join bi.dim d on d.id = p.point_type_id join bi.point_type t on t.name = d.val
            where p.created_at >= '2024-03-31 18:30:00+00' and t.category in ('field', 'document')) q
      group by q.m) x;
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('month', g,
     'case', jsonb_build_object('n', coalesce((c->g::text->>'n')::int, 0), 'avg', (c->g::text->>'avg')::numeric, 'median', (c->g::text->>'median')::numeric, 'p90', (c->g::text->>'p90')::numeric),
     'field', jsonb_build_object('n', coalesce((p->g::text->>'field_n')::int, 0), 'avg', (p->g::text->>'field_avg')::numeric, 'median', (p->g::text->>'field_median')::numeric, 'p90', (p->g::text->>'field_p90')::numeric),
     'document', jsonb_build_object('n', coalesce((p->g::text->>'doc_n')::int, 0), 'avg', (p->g::text->>'doc_avg')::numeric, 'median', (p->g::text->>'doc_median')::numeric, 'p90', (p->g::text->>'doc_p90')::numeric))
     order by g), '[]'::jsonb) from unnest(mm) g);
end $function$;

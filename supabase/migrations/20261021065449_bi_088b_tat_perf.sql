-- Applied to Supabase project via MCP on 20261021065449
-- bi_088b (21-Oct-2026): document rule read once per query (InitPlan) instead of a per-row join; field back-entry flag
create or replace function bi.tat_hours(p_start timestamptz, p_end timestamptz) returns numeric language sql immutable parallel safe as
$f$ select case when p_start is not null and p_end is not null and p_end >= p_start then extract(epoch from p_end - p_start) / 3600.0 end $f$;

update bi.tat_rule set back_entry_minutes = 15, note = note || ' Points reviewed within 15 minutes of assignment are counted as back-entered and flagged.'
 where measure = 'field' and back_entry_minutes is null;

create or replace view bi.v_point as
 SELECT p.point_id, p.case_id, p.point_type, COALESCE(t.category, 'unknown'::text) AS category, t.review_status AS category_review,
    p.created_month, COALESCE(c.recon_unit, p.recon_unit) AS recon_unit, c.location_id, COALESCE(c.client_code, p.client_code_raw) AS client_code,
    p.branch, p.pincode, p.has_address, p.status, p.assign_to, p.verified_by, p.completed_by, p.created_at, p.assigned_at, p.field_reviewed_at, p.completed_at,
        CASE
            WHEN t.category = 'field'::text AND p.assigned_at IS NOT NULL AND p.field_reviewed_at IS NOT NULL AND p.field_reviewed_at >= p.assigned_at AND p.field_reviewed_at < (p.assigned_at + '120 days'::interval) THEN EXTRACT(epoch FROM p.field_reviewed_at - p.assigned_at) / 3600.0
            ELSE NULL::numeric
        END AS field_tat_hours,
    t.category = 'field'::text AND p.assigned_at IS NOT NULL AND p.field_reviewed_at IS NOT NULL AND (p.field_reviewed_at < p.assigned_at OR p.field_reviewed_at >= (p.assigned_at + '120 days'::interval)) AS field_tat_invalid,
        CASE
            WHEN t.category = 'document'::text THEN bi.tat_hours(
              CASE (SELECT r.start_field FROM bi.tat_rule r WHERE r.measure = 'document') WHEN 'assigned_at' THEN p.assigned_at WHEN 'assigned_at_else_created_at' THEN COALESCE(p.assigned_at, p.created_at) ELSE p.created_at END,
              CASE (SELECT r.end_field FROM bi.tat_rule r WHERE r.measure = 'document') WHEN 'field_reviewed_at' THEN p.field_reviewed_at ELSE p.completed_at END)
            ELSE NULL::numeric
        END AS doc_tat_hours,
        CASE
            WHEN t.category = 'tele'::text AND p.completed_at IS NOT NULL AND p.assigned_at IS NOT NULL AND p.completed_at >= p.assigned_at THEN EXTRACT(epoch FROM p.completed_at - p.assigned_at) / 3600.0
            ELSE NULL::numeric
        END AS tele_tat_hours,
        CASE
            WHEN t.category IS DISTINCT FROM 'field'::text THEN NULL::text
            WHEN p.verified_by IS NULL THEN 'unknown_not_verified'::text
            WHEN ev.classification = 'field_executive'::text THEN 'in_force_by_field_executive'::text
            WHEN ev.classification = ANY (ARRAY['back_office'::text, 'mixed'::text]) THEN 'back_office_update_likely_outside_force'::text
            ELSE 'unknown'::text
        END AS processing_route,
    ev.classification AS verifier_class,
    ea.classification AS assignee_class
   FROM bi.fact_point p
     LEFT JOIN bi.point_type t ON t.name = p.point_type
     LEFT JOIN bi.fact_case c ON c.case_id = p.case_id
     LEFT JOIN bi.employee ev ON ev.name_key = p.verified_by
     LEFT JOIN bi.employee ea ON ea.name_key = p.assign_to
  WHERE p.created_at >= '2024-03-31 18:30:00+00'::timestamp with time zone;

do $do$
declare r record; d text := pg_get_functiondef('bi.tat_summary(date,jsonb,text)'::regprocedure); n int;
begin
  if position('field_back_entered' in d) > 0 then return; end if;
  for r in select * from (values
    (1, $a$coalesce((select min_sample from bi.tat_rule where measure = 'case'), 30) ms,$a$,
        $b$coalesce((select min_sample from bi.tat_rule where measure = 'case'), 30) ms,
              coalesce((select back_entry_minutes from bi.tat_rule where measure = 'field'), 15) fbe_min,$b$),
    (2, $a$count(*) filter (where category = 'field') field_points, count(field_tat_hours) field_n,$a$,
        $b$count(*) filter (where category = 'field') field_points, count(field_tat_hours) field_n,
         count(*) filter (where field_tat_hours * 60 < (select fbe_min from rc)) field_back_entered,$b$),
    (3, $a$pa.field_points, pa.field_n,$a$, $b$pa.field_points, pa.field_n, pa.field_back_entered,$b$),
    (4, $a$'p90', field_p90, 'invalid', coalesce(field_invalid, 0),$a$,
        $b$'p90', field_p90, 'invalid', coalesce(field_invalid, 0),
       'back_entered', coalesce(field_back_entered, 0), 'back_entered_share', round(coalesce(field_back_entered, 0)::numeric / nullif(field_n, 0), 4),
       'reliability', case when coalesce(field_n, 0) = 0 then 'unavailable'
                           when field_back_entered::numeric / field_n > 0.5 then 'unreliable'
                           when field_n < (select ms from rc) or field_back_entered::numeric / field_n > 0.2 then 'indicative' else 'ok' end,$b$),
    (5, $a$when coalesce(field_n, 0) = 0 then 'Field points exist but none has both an assignment time and a field-review time'$a$,
        $b$when coalesce(field_n, 0) = 0 then 'Field points exist but none has both an assignment time and a field-review time'
                      when field_back_entered::numeric / field_n > 0.5 then
                        format('%s%% of timed field points were reviewed within %s minutes of assignment (entered after the visit), so this TAT does not show field time',
                               round(100.0 * field_back_entered / field_n), (select fbe_min from rc))$b$)
  ) v(ord, a, b) order by ord loop
    n := (length(d) - length(replace(d, r.a, ''))) / length(r.a);
    if n <> 1 then raise exception 'tat_summary patch %: found % times', r.ord, n; end if;
    d := replace(d, r.a, r.b);
  end loop;
  execute d;
end $do$;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('migration', 'definition_change', 'tat_standard', 'bi_088b', jsonb_build_object('change', 'field back-entry flag; document rule as InitPlan'));

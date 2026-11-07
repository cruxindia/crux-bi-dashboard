-- Applied to Supabase project via MCP on 20261107154224
-- Wave 101b: Ask Crux plan questions — "targets for the next 3, 6 and 12 months" routed to the plan answer; month names in a plan
-- question mean the coming months (not last year's); a question about next quarter leads with next quarter.
do $m$
declare d text := pg_get_functiondef('public.bi_ask3(text, jsonb, uuid)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, $a$monthly targets?|targets? for (january|february$a$, $a$monthly targets?|targets?.{0,40}\mmonths?\M|\mmonths?.{0,25}targets?|next [0-9 ,/and]+months|targets? for (january|february$a$);
  if d = o then raise exception 'routing edit'; end if;
  execute d;
  d := pg_get_functiondef('bi.ask_h_plan(date, jsonb, text)'::regprocedure); o := d;
  d := replace(d, $a$  saved := exists (select 1 from bi.plan_version);$a$,
$a$  m := coalesce((select max(report_month) from bi.zt_snapshot), m);   -- plan questions are about the coming months
  saved := exists (select 1 from bi.plan_version);$a$);
  if d = o then raise exception 'plan edit 1'; end if; o := d;
  d := replace(d, $a$want_targets boolean := q ~ '(next \d+|\d+ months?|three|six|twelve|xyz|year|milestone|motivat|target(s)? for (next|the next|coming|each)|monthly targets?)';$a$,
                  $a$want_targets boolean := q ~ '(next \d+|next [0-9 ,/and]+months|\d+ months?|three|six|twelve|xyz|year|milestone|motivat|target(s)? for (next|the next|coming|each)|monthly targets?|targets?.{0,40}\mmonths?\M)';$a$);
  if d = o then raise exception 'plan edit 2'; end if; o := d;
  d := replace(d, $a$  if (qn->>'shortfall')::numeric > 0 and (qn->>'remaining_workdays')::int > 0 then$a$,
$a$  if mx is null and q ~ 'next quarter' and q !~ 'this quarter' then
    ans := format('Next quarter %s (%s–%s) for %s: plan %s, outlook at current pace %s → %s %s; it needs %s per working day against %s now (%s). This quarter %s: plan %s, outlook %s → %s %s.',
      qx->>'label', to_char((qx->>'from')::date, 'Mon'), to_char((qx->>'to')::date, 'Mon-YY'), sc, bi.fmt_inr((qx->>'plan')::numeric), bi.fmt_inr((qx->>'outlook')::numeric),
      case when (qx->>'delta')::numeric < 0 then 'shortfall' else 'ahead by' end, bi.fmt_inr(abs((qx->>'delta')::numeric)), bi.fmt_inr((qx->>'needed_per_workday')::numeric),
      bi.fmt_inr((qx->>'pace_per_workday')::numeric), bi.fmt_sp((qx->>'needed_vs_pace')::numeric), qn->>'label', bi.fmt_inr((qn->>'plan')::numeric), bi.fmt_inr((qn->>'outlook')::numeric),
      case when (qn->>'delta')::numeric < 0 then 'shortfall' else 'ahead by' end, bi.fmt_inr(abs((qn->>'delta')::numeric)));
  end if;
  if (qn->>'shortfall')::numeric > 0 and (qn->>'remaining_workdays')::int > 0 then$a$);
  if d = o then raise exception 'plan edit 3'; end if;
  execute d;
end $m$;

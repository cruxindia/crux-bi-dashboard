-- Applied to Supabase project via MCP on 20261108053146
-- wave 103c: Ask Crux answers "why is X behind target" / "which teams are furthest from target" with the same root-cause logic as the
-- Root cause page: gap = target − likely month end (so far ÷ usual share of the month), cause = business slowdown (> 5% below business as usual)
-- or target stretch (business at its usual level, likely < 95% of target).
create or replace function bi.ask_h_rca(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path = bi, public as $f$
declare lv text := case when nullif(f->>'location_id', '') is not null then 'client' when nullif(f->>'zone_group', '') is not null then 'location' else 'zone' end;
  rv jsonb; v_l date; v_sh numeric; sc text := bi.ask_scope(f); lvn text; t jsonb; tl numeric; tm numeric; tt numeric; tor numeric;
  v_rows jsonb; v_short numeric; v_slow numeric; v_str numeric; n_slow int; n_str int; n_short int; v_top text; v_over numeric;
begin
  rv := bi.api_drill_ops(m, f, lv, 'revenue');
  select r.month, coalesce((r.inputs->>'share_to_date')::numeric, 1) into v_l, v_sh from bi.potential_run r order by r.run_id desc limit 1;
  if date_trunc('month', m)::date <> v_l then v_sh := 1; end if;
  lvn := case lv when 'zone' then 'zone' when 'location' then 'team' else 'client' end;
  t := rv->'total'; tt := (t->>'target')::numeric; tm := (t->>'mtd')::numeric; tor := (t->>'organic')::numeric; tl := tm / nullif(v_sh, 0);
  with k as (select c->>'group' grp, coalesce((c->>'target')::numeric, 0) tgt, coalesce((c->>'mtd')::numeric, 0) mtd, (c->>'organic')::numeric org
               from jsonb_array_elements(coalesce(rv->'children', '[]'::jsonb)) c),
       k2 as (select *, mtd / nullif(v_sh, 0) lik, mtd / nullif(org, 0) - 1 vsb from k),
       k3 as (select *, tgt - lik gap,
                     case when tgt = 0 then 'no target' when lik >= tgt then 'ahead' when lik >= 0.95 * tgt then 'on track' when vsb < -0.05 then 'business slowdown' else 'target stretch' end cause,
                     row_number() over (order by tgt - lik desc) rn from k2)
  select jsonb_agg(jsonb_build_array(grp, bi.fmt_inr(tgt), bi.fmt_inr(lik), bi.fmt_p(lik / nullif(tgt, 0)), bi.fmt_inr(gap), bi.fmt_sp(vsb), cause) order by gap desc) filter (where gap > 0),
         coalesce(sum(gap) filter (where gap > 0), 0), coalesce(sum(gap) filter (where gap > 0 and cause = 'business slowdown'), 0), coalesce(sum(gap) filter (where gap > 0 and cause = 'target stretch'), 0),
         count(*) filter (where gap > 0 and cause = 'business slowdown'), count(*) filter (where gap > 0 and cause = 'target stretch'), count(*) filter (where gap > 0),
         string_agg(grp || ' ' || bi.fmt_inr(gap) || ' (' || cause || ')', ', ' order by rn) filter (where gap > 0 and rn <= 5), coalesce(-sum(gap) filter (where gap < 0), 0)
    into v_rows, v_short, v_slow, v_str, n_slow, n_str, n_short, v_top, v_over from k3;
  return jsonb_build_object(
    'answer', case when coalesce(tt, 0) = 0 then format('%s, %s: no target to compare with.', sc, to_char(m, 'Mon-YY'))
      when tl >= tt then format('%s, %s: likely month end %s — %s of the %s target, ahead.', sc, to_char(m, 'Mon-YY'), bi.fmt_inr(tl), bi.fmt_p(tl / tt), bi.fmt_inr(tt))
      else format('%s, %s: likely month end %s — %s of the %s target, short by %s. Business so far is %s against its usual level. Of the %s short across %s %ss, %s is business slowdown (%s %ss more than 5%% below their usual level) and %s is target stretch (%s %ss at or above their usual level, target higher)%s. Biggest gaps: %s.',
                  sc, to_char(m, 'Mon-YY'), bi.fmt_inr(tl), bi.fmt_p(tl / tt), bi.fmt_inr(tt), bi.fmt_inr(tt - tl), bi.fmt_sp(tm / nullif(tor, 0) - 1),
                  bi.fmt_inr(v_short), n_short, lvn, bi.fmt_inr(v_slow), n_slow, lvn, bi.fmt_inr(v_str), n_str, lvn,
                  case when v_over > 0 then format('; %s is made up by %ss ahead of target', bi.fmt_inr(v_over), lvn) else '' end, coalesce(v_top, 'none')) end,
    'findings', jsonb_build_object('columns', jsonb_build_array(initcap(lvn), 'Target', 'Likely', 'Likely % of target', 'Gap', 'vs business as usual', 'Cause'), 'rows', coalesce(v_rows, '[]'::jsonb)),
    'drivers', jsonb_build_array('Business slowdown ' || bi.fmt_inr(v_slow), 'Target stretch ' || bi.fmt_inr(v_str)),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Root cause (why) — signals and actions per ' || lvn, 'section', 'rca', 'f', f)),
    'next', jsonb_build_array('Which branches are dormant?', 'What is the target for next month?', 'Is TAT getting worse?'),
    'method', 'Likely month end = expected revenue so far ÷ the usual share of a month reached by this working day (' || round(v_sh * 100, 1) || '%), the same projection as the Overview, Planning and the target sheet. Business slowdown = so far more than 5% below business as usual; target stretch = at or above business as usual but likely under 95% of target.',
    'sources', jsonb_build_array('bi.api_drill_ops (revenue)', 'bi.organic_*', 'bi.potential_run'), 'confidence', 'high');
end $f$;

do $m$ declare d text; o text; begin
  d := pg_get_functiondef('public.bi_ask3(text, jsonb, uuid)'::regprocedure); o := d;
  d := replace(d, $a$    when q ~ '\mtargets?\M' and q ~ '\m(jan(uary)?|feb(ruary)?|march|apr(il)?|june?|july?|aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?)\M' and q !~ '(quarter|\mq[1-4]\M|months)' then 'target_month'$a$,
$a$    when (q ~ '\m(why|reason|reasons|cause|causes)\M' and q ~ '(behind|short|shortfall|miss|missing|below (the )?target|\mgap\M|not on track|not achiev|under ?perform|lagging)') or q ~ '\mroot cause\M'
         or q ~ '(furthest|farthest|most|biggest|worst|largest).{0,30}(behind|from (the )?target|short|\mgap)' or q ~ '\mwhich (teams|locations|zones|clients).{0,30}(behind|short|below (the )?target|miss)' then 'rca'
    when q ~ '\mtargets?\M' and q ~ '\m(jan(uary)?|feb(ruary)?|march|apr(il)?|june?|july?|aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?)\M' and q !~ '(quarter|\mq[1-4]\M|months)' then 'target_month'$a$);
  d := replace(d, $a$    when 'branches' then bi.ask_h_branches(m, f)$a$, $a$    when 'rca' then bi.ask_h_rca(m, f, q)
    when 'branches' then bi.ask_h_branches(m, f)$a$);
  if position('then ''rca''' in d) = 0 or position('bi.ask_h_rca(m, f, q)' in d) = 0 then raise exception 'bi_ask3 anchors not found'; end if;
  execute d;
end $m$;

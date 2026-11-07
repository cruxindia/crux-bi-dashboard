-- Applied to Supabase project via MCP on 20261107185215
-- wave 102o (8-Nov-2026, owner): "next month's target can never be lower than the previous month" means the previous month's ACTUAL business
-- (+2%), not its target; except a month with a strong seasonal signal. Old tracker targets are no longer a floor (dormant pairs still keep theirs).
do $m$
declare d text; o text;
begin
  -- suggested monthly targets: month 1 floor = the pair's last month (current business, projected) instead of the old tracker target
  d := pg_get_functiondef('bi.plan_compute(jsonb)'::regprocedure); o := d;
  d := replace(d, 'c.t0 * case when sg[1] then 1 - dr[1] else 1 + v_gmin end', 'c.pace0 * case when sg[1] then 1 - dr[1] else 1 + v_gmin end');
  d := replace(d, $a$  -- 2. per team x client: seasonal value = (pace + c_k x opportunity) x factor_k; floor = previous target x (1 + gmin) (month 1: the
  --    reference tracker target), strong-signal months excepted;$a$,
                  $a$  -- 2. per team x client: seasonal value = (pace + c_k x opportunity) x factor_k; floor = last month's actual business x (1 + gmin) in
  --    month 1 (owner 8-Nov), then the previous month's target x (1 + gmin) (its business if met); strong-signal months excepted;$a$);
  if d = o or position('c.pace0 * case when sg[1]' in d) = 0 then raise exception 'plan_compute anchor not found'; end if;
  execute d;

  -- target sheet: base = max(plan up to the ceiling, last month's actual + 2% [strong signal: less the allowed fall], BAU + 2%)
  d := pg_get_functiondef('bi.api_target_sheet(date, jsonb, jsonb)'::regprocedure); o := d;
  d := replace(d, 'else greatest(least(r1.plan_rev, r1.u), least(r1.pfl, r1.u), r1.lm_rev * (1 + v_gmin), r1.bau_rev * (1 + v_gmin)) end base_rev,',
                  'else greatest(least(r1.plan_rev, r1.u), r1.lm_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end, r1.bau_rev * (1 + v_gmin)) end base_rev,');
  d := replace(d, $a$                when r1.base_rev = least(r1.pfl, r1.u) then case when r1.pfl > r1.u then 'previous target capped at ' || round((1 + v_cap) * 100) || '% of what the team does' when v_sig then 'previous target less the allowed seasonal fall' else 'previous month''s target + ' || round(v_gmin * 100, 1) || '%' end
                when r1.base_rev = r1.lm_rev * (1 + v_gmin) then 'last month + ' || round(v_gmin * 100, 1) || '%'$a$,
                  $a$                when r1.base_rev = r1.lm_rev * case when v_sig then 1 - v_drop else 1 + v_gmin end then case when v_sig then 'last month''s actual less the allowed seasonal fall' else 'last month''s actual + ' || round(v_gmin * 100, 1) || '%' end$a$);
  d := replace(d, '(plan_rev > u or pfl > u)', 'plan_rev > u');
  d := replace(d, $a$Base = the highest of: plan (up to the ceiling); previous month''s target + ' || round(v_gmin * 100, 1) || '%' || case when v_sig then ' (strong seasonal signal: may fall by up to ' || round(v_drop * 100, 1) || '%)' else '' end
      || ' (up to the ceiling); last month + ' || round(v_gmin * 100, 1) || '%; BAU + '$a$,
                  $a$Base = the highest of: plan (up to the ceiling); last month''s actual business + ' || round(v_gmin * 100, 1) || '%' || case when v_sig then ' (strong seasonal signal: may fall by up to ' || round(v_drop * 100, 1) || '%)' else '' end
      || '; BAU + '$a$);
  if position('least(r1.pfl' in d) > 0 or position('last month''''s actual less' in d) = 0 and position('last month''s actual less' in d) = 0 or position('actual business + ' in d) = 0 then
    raise exception 'api_target_sheet anchors not found';
  end if;
  execute d;

  -- texts in the targets and plan APIs
  d := pg_get_functiondef('bi.api_targets(date, jsonb, jsonb)'::regprocedure); o := d;
  d := replace(d, $a$' No month''s target is below the previous month''s target + ' || round(coalesce((v_params->>'gmin')::numeric, 0.02) * 100, 1) || '% for the same team x client (the first month starts from the ' || to_char(v_ref, 'Mon-YY') || ' tracker target, or the current business when higher), except$a$,
                  $a$' The first month is never below last month''s actual business + ' || round(coalesce((v_params->>'gmin')::numeric, 0.02) * 100, 1) || '% for the same team x client; each later month is at least the previous month''s target + the same (its business if that target is met); no team x client goes above ' || round((1 + coalesce((v_params->>'cap')::numeric, 0.5)) * 100) || '% of what it does (best of current pace and last 3 months average), and a pair with no business keeps its old tracker target; except$a$);
  if d = o then raise exception 'api_targets text anchor not found'; end if;
  execute d;
  d := pg_get_functiondef('bi.api_plan(date, jsonb, jsonb)'::regprocedure); o := d;
  d := replace(d, $a$and never below the previous month''s target + 2% except a month with a strong seasonal signal)$a$,
                  $a$never below last month''s actual business + 2% in the first month nor the previous month''s target after that, never above 1.5× what the team does, except a month with a strong seasonal signal)$a$);
  if d = o then raise exception 'api_plan text anchor not found'; end if;
  execute d;
end $m$;

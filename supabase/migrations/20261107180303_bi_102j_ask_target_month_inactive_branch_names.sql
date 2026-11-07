-- Applied to Supabase project via MCP on 20261107180303
-- wave 102j (7-Nov-2026): Ask Crux answers "target for <month>" from the target sheet, lists clients inactive PAN India,
-- and names the dormant / never-active branches of a team or client
create or replace function bi.ask_h_inactive(m date, f jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare v_month date; v_inp jsonb; v_rows jsonb; v_ans text;
begin
  select r.month, r.inputs into v_month, v_inp from bi.potential_run r order by r.run_id desc limit 1;
  with c as (select x fam from jsonb_array_elements_text(coalesce(v_inp->'inactive_clients', '[]'::jsonb)) x),
  h as (select c.fam,
               (select max(v.month) from bi.v_month_business v left join bi.client cl on cl.code = v.client_code where coalesce(cl.family, v.client_code) = c.fam and v.cases > 0) last_m,
               (select coalesce(sum(v.cases), 0) from bi.v_month_business v left join bi.client cl on cl.code = v.client_code where coalesce(cl.family, v.client_code) = c.fam) cases
          from c)
  select jsonb_agg(jsonb_build_array(fam, coalesce(to_char(last_m, 'Mon-YY'), 'never'), bi.fmt_n(cases)) order by last_m desc nulls last, fam),
         format('%s clients have had no tracker cases anywhere in India in the last three months (to %s), so they are left out of potential and targets (owner decision, 7-Nov-2026): %s.',
                count(*), to_char(v_month, 'Mon-YY'),
                string_agg(fam || case when last_m is not null then ' (last case ' || to_char(last_m, 'Mon-YY') || ', ' || bi.fmt_n(cases) || ' cases on record)' else ' (no cases on record)' end, '; ' order by last_m desc nulls last, fam))
    into v_rows, v_ans from h;
  return jsonb_build_object('answer', coalesce(v_ans, 'Every client had tracker cases in the last three months.'),
    'findings', jsonb_build_object('columns', jsonb_build_array('Client', 'Last case', 'Cases on record'), 'rows', coalesce(v_rows, '[]'::jsonb)),
    'drivers', '[]'::jsonb, 'risks', '[]'::jsonb,
    'opportunities', jsonb_build_array('Winning back a client that is inactive across India needs management action (empanelment, relationship), so it is not part of team targets.'),
    'actions', '[]'::jsonb,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Planning & forecasting → Potential & branches', 'section', 'planning', 'f', f)),
    'next', jsonb_build_array('What is the potential?', 'Which branches are dormant?', 'What is the target for next month?'),
    'method', 'Inactive PAN India = no tracker cases for the client family in any team in the last three months including the latest tracker month (bi.potential_run.inputs.inactive_clients, set by bi.potential_refresh).',
    'sources', jsonb_build_array('bi.potential_run', 'bi.v_month_business', 'bi.client'), 'confidence', 'high');
end $f$;

create or replace function bi.ask_h_branch_names(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare v_st text := case when q ~ 'never' then 'never' when q ~ '(dormant|quiet|stopped|not sending|no case|went silent)' then 'dormant'
                          when q ~ '\mactive\M' and q !~ '(inactive|not active)' then 'active' else 'inactive' end;
        j jsonb; s jsonb; sc text := bi.ask_scope(f); v_top text; v_rows jsonb; lbl text;
begin
  j := bi.api_branch_list(f, jsonb_build_object('status', v_st, 'limit', 15)); s := j->'summary';
  lbl := case v_st when 'never' then 'never-active' when 'dormant' then 'dormant' when 'active' then 'active' else 'not active (dormant or never active)' end;
  select string_agg(format('%s (%s %s, %s, team %s) — %s, about %s a month', x->>'branch', x->>'client_family', x->>'branch_code', coalesce(x->>'city', '–'), x->>'location',
                           case when x->>'last_case_month' is null then 'never active' else 'last case ' || to_char((x->>'last_case_month')::date, 'Mon-YY') end,
                           bi.fmt_inr(coalesce((x->>'est_rev_month')::numeric, 0))), '; ' order by o) filter (where o <= 8),
         jsonb_agg(jsonb_build_array(x->>'client_family', x->>'branch', x->>'branch_code', coalesce(x->>'city', '–'), x->>'location', x->>'status',
                                     coalesce(to_char((x->>'last_case_month')::date, 'Mon-YY'), 'never'), bi.fmt_inr(coalesce((x->>'est_rev_month')::numeric, 0))) order by o)
    into v_top, v_rows from jsonb_array_elements(j->'rows') with ordinality t(x, o);
  return jsonb_build_object(
    'answer', format('%s: %s verified branches of active clients — %s active, %s dormant, %s never active. %s %s branches, largest estimated value first: %s.%s',
                     sc, bi.fmt_n((s->>'total')::numeric), bi.fmt_n((s->>'active')::numeric), bi.fmt_n((s->>'dormant')::numeric), bi.fmt_n((s->>'never')::numeric),
                     bi.fmt_n((j->>'total_rows')::numeric), lbl, coalesce(v_top, 'none'),
                     ' The full list with names, codes and cities (Excel download): Planning & forecasting → Potential & branches.'),
    'findings', jsonb_build_object('columns', jsonb_build_array('Client', 'Branch', 'Code', 'City', 'Team', 'Status', 'Last case', 'Est. ₹ / month'), 'rows', coalesce(v_rows, '[]'::jsonb)),
    'drivers', '[]'::jsonb, 'risks', '[]'::jsonb, 'opportunities', '[]'::jsonb,
    'actions', case when (s->>'dormant')::numeric > 0 then jsonb_build_array(bi.ask_act('High', 'Call the dormant branches first (they sent cases this year)', 'Listed by estimated value', 'Branch managers / team heads', null)) else '[]'::jsonb end,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open the branch list (Planning & forecasting)', 'section', 'planning', 'f', f)),
    'next', jsonb_build_array('Which branches are never active here?', 'What is the potential here?', 'What is the target for next month?'),
    'method', j->>'method', 'sources', jsonb_build_array('bi.client_branch_master', 'bi.branch_activity', 'bi.v_month_business'), 'confidence', 'high');
end $f$;

create or replace function bi.ask_h_target_month(m date, f jsonb, q text) returns jsonb
language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare v_l date := (select r.month from bi.potential_run r order by r.run_id desc limit 1); v_mon int; v_m date; j jsonb; t jsonb; br jsonb; sc text := bi.ask_scope(f); v_rows jsonb;
begin
  v_mon := case when q ~ '\mjan' then 1 when q ~ '\mfeb' then 2 when q ~ '\mmarch\M' then 3 when q ~ '\mapr' then 4 when q ~ '\mjune?\M' then 6 when q ~ '\mjuly?\M' then 7
                when q ~ '\maug' then 8 when q ~ '\msept?' then 9 when q ~ '\moct' then 10 when q ~ '\mnov' then 11 when q ~ '\mdec' then 12 end;
  if v_mon is null then return bi.ask_h_plan(m, f, q); end if;
  v_m := (v_l + make_interval(months => ((v_mon - extract(month from v_l)::int + 12) % 12)))::date;
  if v_m <= v_l then return bi.ask_h_plan(m, f, q); end if;
  j := bi.api_target_sheet(v_m, f, '{}'::jsonb);
  if j ? 'error' then return jsonb_build_object('answer', j->>'error', 'confidence', 'low'); end if;
  t := j->'totals'; br := j->'bridge';
  select jsonb_agg(jsonb_build_array(x->>'location', x->>'client', bi.fmt_n((x->>'lm_cases')::numeric), bi.fmt_n((x->>'tgt_cases')::numeric), bi.fmt_inr((x->>'tgt_rev')::numeric), bi.fmt_p((x->>'vs_last')::numeric)) order by (x->>'tgt_rev')::numeric desc)
    into v_rows from (select x from jsonb_array_elements(j->'rows') x order by (x->>'tgt_rev')::numeric desc limit 12) z;
  return jsonb_build_object(
    'answer', format('Target for %s (%s): %s — %s cases. Built from last month (%s, %s) %s: BAU change %s, plan above BAU %s, floors %s, quarter catch-up %s%s. Plan %s; previous month''s target %s; potential %s. Admins can download the sheet by team × client: Planning & forecasting → Targets by month.',
                     to_char(v_m, 'Mon-YY'), sc, bi.fmt_inr((t->>'tgt_rev')::numeric), bi.fmt_n((t->>'tgt_cases')::numeric),
                     to_char((j->>'previous_month')::date, 'Mon-YY'), j->>'previous_basis', bi.fmt_inr((t->>'lm_rev')::numeric),
                     bi.fmt_sinr((br->1->>'value')::numeric), bi.fmt_sinr((br->2->>'value')::numeric), bi.fmt_sinr((br->3->>'value')::numeric), bi.fmt_sinr((br->4->>'value')::numeric),
                     case when (t->>'cu_wanted')::numeric > (t->>'catchup_rev')::numeric + 1 then ' (' || bi.fmt_inr((t->>'cu_wanted')::numeric) || ' wanted for the ' || (j->>'quarter_label') || ' shortfall; the rest is capped at potential and last month + 50%)' else '' end,
                     bi.fmt_inr((t->>'plan_rev')::numeric), bi.fmt_inr((t->>'prev_rev')::numeric), bi.fmt_inr((t->>'pot_rev')::numeric)),
    'findings', jsonb_build_object('columns', jsonb_build_array('Location', 'Client', 'Last month cases', 'Target cases', 'Target ₹', 'vs last month'), 'rows', coalesce(v_rows, '[]'::jsonb)),
    'drivers', '[]'::jsonb, 'risks', case when j->>'previous_basis' <> 'actual' then jsonb_build_array('Last month is ' || (j->>'previous_basis') || ', not a final actual: the target moves when the tracker arrives.') else '[]'::jsonb end,
    'opportunities', '[]'::jsonb, 'actions', '[]'::jsonb,
    'chart', jsonb_build_object('type', 'bar', 'title', 'How the ' || to_char(v_m, 'Mon-YY') || ' target is built', 'unit', '₹',
       'labels', (select jsonb_agg(x->>'label' order by o) from jsonb_array_elements(br) with ordinality t(x, o)),
       'series', jsonb_build_array(jsonb_build_object('name', '₹', 'values', (select jsonb_agg((x->>'value')::numeric order by o) from jsonb_array_elements(br) with ordinality t(x, o))))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open Targets by month (Planning & forecasting)', 'section', 'planning', 'f', f)),
    'next', jsonb_build_array('Are we on track for this quarter?', 'What targets follow for the next 3, 6 and 12 months?', 'Which branches are dormant?'),
    'method', j->>'method', 'sources', jsonb_build_array('bi.api_target_sheet', 'bi.organic_pairs', 'bi.plan_compute', 'bi.potential_cell', 'bi.v_month_business'), 'confidence', 'medium');
end $f$;
revoke all on function bi.ask_h_inactive(date, jsonb), bi.ask_h_branch_names(date, jsonb, text), bi.ask_h_target_month(date, jsonb, text) from public, anon, authenticated;

do $m$
declare d text := pg_get_functiondef('public.bi_ask3(text, jsonb, uuid)'::regprocedure); o text := d;
begin
  if position('''target_month''' in d) = 0 then
    d := replace(d, $a$    when q ~ '(carr(y|ies|ying|ied)|burden|$a$,
      $a$    when q ~ '\mtargets?\M' and q ~ '\m(jan(uary)?|feb(ruary)?|march|apr(il)?|june?|july?|aug(ust)?|sept?(ember)?|oct(ober)?|nov(ember)?|dec(ember)?)\M' and q !~ '(quarter|\mq[1-4]\M|months)' then 'target_month'
    when q ~ '(client|bank)' and q ~ '(inactive|no business|not active|stopped|zero business|no cases|dormant)' and q !~ '\mbranch' then 'inactive_clients'
    when q ~ '\mbranch(es)?\M' and q ~ '(which|list|name|names|show|give|tell)' and q ~ '(dormant|inactive|never|not active|activat|quiet|stopped|no case|not sending)' then 'branch_names'
    when q ~ '(carr(y|ies|ying|ied)|burden|$a$);
    d := replace(d, $a$    when 'branches' then bi.ask_h_branches(m, f)$a$,
      $a$    when 'target_month' then bi.ask_h_target_month(m, f, q)
    when 'inactive_clients' then bi.ask_h_inactive(m, f)
    when 'branch_names' then bi.ask_h_branch_names(m, f, q)
    when 'branches' then bi.ask_h_branches(m, f)$a$);
    if position('''target_month''' in d) = 0 or position('ask_h_branch_names' in d) = 0 then raise exception 'bi_ask3 anchors not found'; end if;
    execute d;
  end if;
end $m$;

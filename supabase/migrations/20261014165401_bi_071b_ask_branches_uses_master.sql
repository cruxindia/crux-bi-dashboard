-- Applied to Supabase project via MCP on 20261014165401
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.bi_ask(text,jsonb,uuid)'::regprocedure);
  d2 := replace(d, $o$    src := '["Force1 Case Wise (bi.case_store) via bi.api_branches"]'; meth := a->'method'->>'rules'; conf := 'medium';
    lim := 'Branch universe = branches seen in Force1 only; verified client branch master not yet supplied, so coverage % and never-activated branches cannot be computed. Opportunity values are peer-based estimates, not confirmed leakage.';$o$,
  $n$    begin
      x := public.bi_call('branch_coverage', jsonb_build_object('filters', f));
      if (x->'totals'->>'verified_active') is not null then
        txt := txt || format(' Client branch master: %s verified branches of these clients in Crux territories; %s sent a Force1 case in the last 6 months (coverage %s%% where branch codes can be matched); %s have never sent a case. Highest indicative levels among never-activated branches: %s.',
          x->'totals'->>'verified_active', x->'totals'->>'active_with_crux_6m', round((x->'totals'->>'coverage_6m')::numeric * 100, 1), x->'totals'->>'never_activated',
          coalesce((select string_agg(format('%s %s, %s (about %s cases/month at peer median)', e->>'client', e->>'branch', coalesce(e->>'city', e->>'district'), e->>'peer_cases_per_month'), '; ')
                    from (select e from jsonb_array_elements(x->'never_activated') e where e->>'peer_cases_per_month' is not null limit 3) z), 'none with a peer benchmark'));
      end if;
    exception when others then null;
    end;
    src := '["Force1 Case Wise (bi.case_store) via bi.api_branches", "Client branch master (RBI IFSC directory, official locators) via bi.api_branch_coverage"]'; meth := a->'method'->>'rules'; conf := 'medium';
    lim := 'Coverage counts a branch as active when its bank branch code matches a Force1 case; lists taken from lender websites have no codes. Indicative levels are peer medians (at least 5 active branches of the same client in the same location), not forecasts or confirmed leakage.';$n$);
  if d2 = d then raise exception 'anchor'; end if;
  execute d2;
end $$;

-- Applied to Supabase project via MCP on 20261029051209
-- bi_097g (29-Oct-2026): Ask Crux conversation fixes from the browser review.
-- * "what about …" follow-ups keep the previous question's topic and scope; only the period or place named changes.
-- * "show me the cases behind it" gets the Force1 counts for the scope and a branch drill-down (the case list stays behind the administrator sign-in).
-- * yes / no forecast questions ("Will we reach the target?") start with Yes or No.
-- * receipts: "no location" and "not credited to one manager" are stated separately (they were one figure labelled "not tied to a location").
create or replace function bi.ask_h_cases(m date, f jsonb) returns jsonb language plpgsql stable security definer set search_path to 'bi', 'public' as $f$
declare r record;
begin
  select count(*) filter (where received_month = m) rcv, count(*) filter (where received_month = m and completed_at is not null) done,
         count(*) filter (where completed_at is null) open_now, count(*) filter (where completed_at is null and received_at < now() - interval '7 days') o7
    into r from bi.case_store c
   where (c.received_month = m or c.completed_at is null) and bi.loc_ok(c.location_id, c.recon_unit, f) and bi.fam_ok(c.client_code, f);
  return jsonb_build_object(
    'answer', format('%s Force1 cases were received in %s for this selection (%s of them completed); %s are open today, %s of those older than 7 days. Use the branch breakdown below to go location → client → branch. The case list itself (case ID, branch, status, TAT) is in TAT & operations → Records and needs an administrator sign-in.',
      bi.fmt_n(r.rcv), to_char(m, 'Mon YYYY'), bi.fmt_n(r.done), bi.fmt_n(r.open_now), bi.fmt_n(r.o7)),
    'findings', jsonb_build_object('columns', jsonb_build_array('Measure', 'Cases'),
      'rows', jsonb_build_array(jsonb_build_array('Received in ' || to_char(m, 'Mon YYYY'), bi.fmt_n(r.rcv)), jsonb_build_array('Completed (of those)', bi.fmt_n(r.done)),
                                jsonb_build_array('Open today', bi.fmt_n(r.open_now)), jsonb_build_array('Open > 7 days', bi.fmt_n(r.o7)))),
    'drill', jsonb_build_array(jsonb_build_object('label', 'Branch breakdown for this selection', 'f', f, 'level', 'branch'), jsonb_build_object('label', 'Open TAT & operations', 'section', 'tat')),
    'next', jsonb_build_array('How many cases are open and how old are they?', 'Where is TAT increasing?'),
    'method', 'Force1 Case Wise for the same filters: received in the month by received date (IST); open = not completed.', 'sources', jsonb_build_array('Force1 Case Wise'),
    'confidence', 'high', 'limitations', 'Case-level records are shown only to administrators.');
end $f$;

do $do$
declare d text; i int; r text[][] := array[
  [$o$pre text := ''; u numeric; tot numeric;$o$, $n$pre text := ''; u numeric; tot numeric; prev_intent text; loc0 numeric; ofc jsonb;$n$],
  [$o$  else select filters into prev from bi.ai_message where conversation_id = conv order by id desc limit 1; end if;$o$,
   $n$  else select filters, intent into prev, prev_intent from bi.ai_message where conversation_id = conv order by id desc limit 1; end if;$n$],
  [$o$    when q ~ '\mwho\M' and q ~ '(handles?|handling|manag|looks? after|in charge|responsib|owns?|takes? care)' then 'bm'$o$,
   $n$    when prev_intent in ('overview', 'shortfall', 'growth', 'tat', 'force1', 'force1_recon', 'forecast', 'health', 'priorities', 'branches', 'collections', 'revenue_growth', 'bm', 'revenue_now', 'ops', 'cases')
         and q ~ '^(and |so |ok |okay )?(what|how) about\M' and q !~ '(\mtat\M|force ?1|collect|outstanding|revenue|branch|data|forecast|issue|backlog|\mcases\M)' then prev_intent
    when q ~ '(show|list|open|see|give|get)\M.{0,40}\m(cases|records|files)\M' or q ~ '\m(cases|records) (behind|for (it|this|that))' then 'cases'
    when q ~ '\mwho\M' and q ~ '(handles?|handling|manag|looks? after|in charge|responsib|owns?|takes? care)' then 'bm'$n$],
  [$o$    when 'ops' then bi.ask_h_ops(m, f, q)$o$, $n$    when 'ops' then bi.ask_h_ops(m, f, q)
    when 'cases' then bi.ask_h_cases(m, f)$n$],
  [$o$      if tot > 0 and u is not null then
        pre := format('%s of %s receipts (to %s) are not yet tied to a location: %s of %s. A receipt is tied through the invoice it settles and, when it is not linked to an invoice, through the paying bank branch; the rest stay unallocated rather than guessed. ',
          bi.fmt_p(u / tot), to_char((ov->'finance'->>'receipt_month')::date, 'Mon YYYY'), to_char((ov->'finance'->>'receipts_through')::date, 'DD-Mon'), bi.fmt_inr(u), bi.fmt_inr(tot));
      end if;$o$,
   $n$      loc0 := (select coalesce(sum(a2.amt), 0) from bi.fin_attr a2 where a2.kind = 'collected' and coalesce(a2.location_id, 0) = 0 and a2.m = (ov->'finance'->>'receipt_month')::date
                  and a2.upload_id in (select id from bi.fin_upload where kind = 'collection' and status = 'committed'));
      if tot > 0 and u is not null then
        pre := format('%s of %s receipts (to %s) have no location: %s of %s. A further %s (%s) is tied only to a zone with more than one manager, or has no client, so it is not credited to a single manager. A receipt is tied through the invoice it settles and, when it is not linked to an invoice, through the paying bank branch; nothing is guessed. ',
          bi.fmt_p(loc0 / tot), to_char((ov->'finance'->>'receipt_month')::date, 'Mon YYYY'), to_char((ov->'finance'->>'receipts_through')::date, 'DD-Mon'), bi.fmt_inr(loc0), bi.fmt_inr(tot),
          bi.fmt_inr(greatest(u - loc0, 0)), bi.fmt_p(greatest(u - loc0, 0) / tot));
      end if;$n$],
  [$o$  if pre <> '' then a := jsonb_set(a, '{answer}', to_jsonb(pre || coalesce(a->>'answer', ''))); end if;$o$,
   $n$  if intent = 'forecast' and q ~ '^(will|are|is|can|do|does|did|shall|have|has)\M' then
    ofc := public.bi_call('overview', jsonb_build_object('month', m, 'filters', f));
    if nullif(ofc->>'target_cases', '')::numeric > 0 and nullif(ofc->'forecast'->>'curve_projection', '') is not null then
      pre := pre || case when (ofc->'forecast'->>'curve_projection')::numeric >= (ofc->>'target_cases')::numeric
                         then format('Yes, at the current pace — projected %s cases against the %s target. ', bi.fmt_n((ofc->'forecast'->>'curve_projection')::numeric), bi.fmt_n((ofc->>'target_cases')::numeric))
                         else format('No, not at the current pace — projected %s cases against the %s target (%s). ', bi.fmt_n((ofc->'forecast'->>'curve_projection')::numeric), bi.fmt_n((ofc->>'target_cases')::numeric),
                                     bi.fmt_p((ofc->'forecast'->>'curve_projection')::numeric / (ofc->>'target_cases')::numeric)) end;
    end if;
  end if;
  if pre <> '' then a := jsonb_set(a, '{answer}', to_jsonb(pre || coalesce(a->>'answer', ''))); end if;$n$]];
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'bi_ask3 fragment % not found exactly once', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
end $do$;

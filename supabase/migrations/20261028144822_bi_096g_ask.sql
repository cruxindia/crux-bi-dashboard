-- Applied to Supabase project via MCP on 20261028144822
-- bi_096g (28-Oct-2026): Ask Crux routing fixes from the 30-question evaluation.
-- * full client names ("Bank of Maharashtra") resolve to the client family; place-name spellings ("Bhubaneswar") resolve through the place table
-- * "who handles …" goes to the branch-manager answer and leads with the mapped people for that location (client-specific when a client word is named)
-- * open cases / backlog / age questions get their own answer (bi.api_ops); receipts not tied to a location, the outstanding summary-vs-sheets gap
--   and gross / not-linked / net outstanding are stated explicitly; "ahead of / on target" premises are checked against the working-day pace.
create table if not exists bi.client_name_alias (alias text primary key, family text not null, note text);
alter table bi.client_name_alias enable row level security;
insert into bi.client_name_alias(alias, family, note) values
  ('bank of maharashtra', 'BOM', 'public bank name'), ('maharashtra bank', 'BOM', 'public bank name'),
  ('state bank of india', 'SBI', 'public bank name'), ('state bank', 'SBI', 'public bank name'),
  ('bank of baroda', 'BOB', 'public bank name'), ('baroda', 'BOB', 'public bank name'),
  ('bank of india', 'BOI', 'public bank name'), ('union bank', 'UNION', 'public bank name'), ('union bank of india', 'UNION', 'public bank name'),
  ('canara bank', 'CANB', 'public bank name'), ('canara', 'CANB', 'public bank name'), ('idbi bank', 'IDBI', 'public bank name'),
  ('lic housing', 'LICHFL', 'public lender name'), ('lic housing finance', 'LICHFL', 'public lender name'), ('lic hfl', 'LICHFL', 'public lender name')
on conflict (alias) do nothing;

create or replace function bi.ask_h_ops(m date, f jsonb, q text) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare o jsonb; ag text; n7 numeric; n30 numeric; cl numeric; t jsonb;
begin
  o := bi.api_ops(m, f); t := coalesce(o->'tat', '{}'::jsonb);
  cl := (o->>'closing_backlog')::numeric; n7 := (o->>'over_7_days')::numeric;
  n30 := (select (x->>'cases')::numeric from jsonb_array_elements(o->'ageing') x where x->>'bucket' = '>30 days');
  select string_agg(format('%s %s', x->>'bucket', bi.fmt_n((x->>'cases')::numeric)), ' · ' order by i) into ag from jsonb_array_elements(o->'ageing') with ordinality z(x, i);
  return jsonb_build_object(
    'answer', format('%s Force1 cases open at the end of %s (opening backlog %s + received %s − completed %s this month). By age: %s. %s (%s) are older than 7 days and %s older than 30 days; the oldest has been open %s days. Cases completed this month: median %s h, 90th percentile %s h.',
       bi.fmt_n(cl), to_char((o->>'as_of')::date, 'DD-Mon-YYYY'), bi.fmt_n((o->>'opening_backlog')::numeric), bi.fmt_n((o->>'received_mtd')::numeric), bi.fmt_n((o->>'closed_mtd')::numeric),
       coalesce(ag, 'none'), bi.fmt_n(n7), bi.fmt_p(n7 / nullif(cl, 0)), bi.fmt_n(coalesce(n30, 0)), coalesce(o->>'oldest_days', '–'), coalesce(t->>'median_hours', '–'), coalesce(t->>'p90_hours', '–')),
    'findings', jsonb_build_object('columns', jsonb_build_array('Location', 'Open', 'Older than 7 days', 'Older than 30 days', 'Oldest (days)'),
       'rows', (select coalesce(jsonb_agg(jsonb_build_array(coalesce(x->>'location', 'not identified'), bi.fmt_n((x->>'open')::numeric), bi.fmt_n((x->>'over_7')::numeric), bi.fmt_n((x->>'over_30')::numeric), round((x->>'oldest_days')::numeric))), '[]')
                  from (select x from jsonb_array_elements(o->'ageing_by_location') x order by (x->>'over_30')::numeric desc nulls last, (x->>'open')::numeric desc limit 10) z)),
    'chart', jsonb_build_object('type', 'bar', 'title', 'Open cases by age, end of ' || to_char((o->>'as_of')::date, 'DD-Mon'), 'unit', 'cases',
       'labels', (select jsonb_agg(x->>'bucket' order by i) from jsonb_array_elements(o->'ageing') with ordinality z(x, i)),
       'series', jsonb_build_array(jsonb_build_object('name', 'Open cases', 'values', (select jsonb_agg((x->>'cases')::numeric order by i) from jsonb_array_elements(o->'ageing') with ordinality z(x, i))))),
    'drivers', '[]'::jsonb,
    'risks', case when n30 > 0 then jsonb_build_array(format('%s open cases are older than 30 days.', bi.fmt_n(n30))) else '[]'::jsonb end,
    'opportunities', '[]'::jsonb,
    'actions', case when n30 > 0 then jsonb_build_array(bi.ask_act('High', 'Review the open cases older than 30 days, location by location', format('%s cases, oldest %s days', bi.fmt_n(n30), o->>'oldest_days'), 'Operations handler / location manager', 'Close or cancel stale cases so the backlog reflects live work')) else '[]'::jsonb end,
    'drill', jsonb_build_array(jsonb_build_object('label', 'Open case flow and ageing', 'section', 'tat')),
    'next', jsonb_build_array('Where is TAT increasing?', 'Which locations have the most cases older than 30 days?'),
    'method', o->>'method', 'sources', jsonb_build_array('Force1 Case Wise (bi.api_ops)'), 'confidence', 'high',
    'limitations', 'Cases are Force1 cases; the Zonal Tracker daily count is a different measure and is not added.');
end $f$;

do $do$
declare d text; r text[][] := array[
  -- declare block: new variables
  [$o$mid bigint; mm int; yy int; mx date; nn int; entity boolean := false; notes text := ''; amb text; bmn text;$o$,
   $n$mid bigint; mm int; yy int; mx date; nn int; entity boolean := false; notes text := ''; amb text; bmn text; ov jsonb; tg numeric; mtd numeric; wp numeric; who_txt text; kw text; rc jsonb; pre text := ''; u numeric; tot numeric;$n$],
  -- full client names
  [$o$  if fam is not null then f := f || jsonb_build_object('client_family', fam); entity := true; end if;$o$,
   $n$  if fam is null then select x.family into fam from bi.client_name_alias x where q ~ ('\m' || x.alias || '\M') order by length(x.alias) desc limit 1; end if;
  if fam is not null then f := f || jsonb_build_object('client_family', fam); entity := true; end if;$n$],
  -- place spellings through the place table when no location / zone word matched
  [$o$   where q ~ ('\m' || ws.w || '\M') order by length(z.label) limit 1;$o$,
   $n$   where q ~ ('\m' || ws.w || '\M') order by length(z.label) limit 1;
  if loc.id is null and zg is null then
    select l.id, l.label, 1::bigint n into loc
      from (select w, i from regexp_split_to_table(q, '[^a-z]+') with ordinality t(w, i)
             where length(w) >= 5 and w not in ('india', 'state', 'total', 'month', 'where', 'which', 'about', 'their', 'there', 'share', 'cases', 'target', 'zones', 'locations', 'happening')) z
      cross join lateral (select bi.loc_of_place(initcap(z.w), 'x') lid) p join bi.location l on l.id = p.lid
     where not l.is_rollup order by z.i limit 1;
  end if;$n$],
  -- intents: "who handles …" → branch managers
  [$o$    when bmn is not null or q ~ '(branch.manager|\mbms?\M|\mmanagers?\M|hand.?over)' then 'bm'$o$,
   $n$    when q ~ '\mwho\M' and q ~ '(handles?|handling|manag|looks? after|in charge|responsib|owns?|takes? care)' then 'bm'
    when bmn is not null or q ~ '(branch.manager|\mbms?\M|\mmanagers?\M|hand.?over)' then 'bm'$n$],
  -- receipts not tied / not linked / unadjusted → collections
  [$o$pending payment|receivable)' then 'collections'$o$,
   $n$pending payment|receivable|\mreceipts?\M|not tied|unlinked|not linked|unadjusted)' then 'collections'$n$],
  -- open cases, backlog and their age → operations
  [$o$    when q ~ '(\mtat\M|turnaround|turn around|slow|delay|time taken|how long|sla|ageing|aging)' then 'tat'$o$,
   $n$    when q ~ '(backlog|open cases|cases (are |still )?(open|pending)|pending cases|older than \d+ ?days|how old|open for (more|over|longer)|(ageing|aging) of (the )?(open|pending|cases))' then 'ops'
    when q ~ '(\mtat\M|turnaround|turn around|slow|delay|time taken|how long|sla|ageing|aging)' then 'tat'$n$],
  -- "ahead of / above / on target" → gap vs target with a premise check
  [$o$    when q ~ '(forecast|projection|projected|month.end|will we (hit|make|reach|achieve)|on track|reach (the )?target|achieve (the )?target)' then 'forecast'$o$,
   $n$    when q ~ '(ahead of|above|beat(ing)?|exceed(ing|ed)?|over|\mon) (the |its |their )?(target|plan)' then 'shortfall'
    when q ~ '(forecast|projection|projected|month.end|will we (hit|make|reach|achieve)|on track|reach (the )?target|achieve (the )?target)' then 'forecast'$n$],
  [$o$    when 'bm' then bi.ask_h_bm(m, f, q, bmn)$o$,
   $n$    when 'bm' then bi.ask_h_bm(m, f, q, bmn)
    when 'ops' then bi.ask_h_ops(m, f, q)$n$],
  -- lead sentences
  [$o$  scope := case when f - 'client_family' = '{}'::jsonb then 'Pan India'$o$,
   $n$  if intent = 'shortfall' and q ~ '^(why|is|are|how come|so)\M' and q ~ '(ahead of|above|beat(ing)?|exceed(ing|ed)?|over|\mon) (the |its |their )?(target|plan)' then
    ov := public.bi_call('overview', jsonb_build_object('month', m, 'filters', f));
    tg := nullif(ov->>'target_cases', '')::numeric; mtd := nullif(ov->>'mtd_cases', '')::numeric;
    wp := nullif(ov->'forecast'->>'workdays_elapsed', '')::numeric / nullif(nullif(ov->'forecast'->>'workdays_in_month', '')::numeric, 0);
    if tg > 0 and mtd is not null and wp is not null then
      pre := case when mtd >= round(tg * wp) then format('Yes — ahead of the working-day pace: %s cases so far vs %s needed by now (month target %s). ', bi.fmt_n(mtd), bi.fmt_n(round(tg * wp)), bi.fmt_n(tg))
                  else format('Not ahead — %s cases so far vs %s needed by now at the working-day pace (month target %s): %s behind. ', bi.fmt_n(mtd), bi.fmt_n(round(tg * wp)), bi.fmt_n(tg), bi.fmt_n(round(tg * wp) - mtd)) end;
    end if;
  elsif intent = 'bm' and q ~ '\mwho\M' and nullif(f->>'location_id', '') is not null then
    select string_agg(z.t, '|') into kw from (select distinct upper(w) t from regexp_split_to_table(q, '[^a-z0-9]+') w where length(w) >= 3) z
     where exists (select 1 from bi.client c where c.code ~ ('_' || z.t || '(_|$)'));
    select string_agg(format('%s — %s', coalesce(c.label, 'clients without their own manager'), b.manager), '; ' order by b.client_code nulls last) into who_txt
      from bi.branch_manager b left join bi.client c on c.code = b.client_code
     where b.active and b.location_id = (f->>'location_id')::int
       and coalesce(b.valid_from, date '1900-01-01') <= least(current_date, (m + interval '1 month - 1 day')::date)
       and coalesce(b.valid_to, date '2999-12-31') >= least(current_date, (m + interval '1 month - 1 day')::date)
       and (kw is null or b.client_code ~ ('_(' || kw || ')(_|$)'));
    select concat_ws('; ', who_txt, string_agg(format('%s: %s', replace(r.role, '_', ' '), r.person), '; ')) into who_txt
      from bi.person_role r where r.active and r.location_id = (f->>'location_id')::int
       and coalesce(r.valid_from, date '1900-01-01') <= current_date and coalesce(r.valid_to, date '2999-12-31') >= current_date;
    if nullif(who_txt, '') is not null then
      pre := format('%s on %s — mapped people: %s. ', (select label from bi.location where id = (f->>'location_id')::int), to_char(least(current_date, (m + interval '1 month - 1 day')::date), 'DD-Mon-YYYY'), who_txt);
    end if;
  elsif intent = 'collections' and f - 'client_family' = '{}'::jsonb and not (f ? 'client_family') then
    if q ~ '(summary|sheet|match|reconcil|differ|discrepan)' then
      rc := bi.api_os_recon();
      if coalesce((rc->>'available')::boolean, false) then
        pre := case when (rc->>'reconciled')::boolean then format('The outstanding workbook of %s reconciles: summary sheet = location sheets (%s). ', to_char((rc->>'as_of')::date, 'DD-Mon-YYYY'), bi.fmt_inr((rc->>'gross')::numeric))
          else format('Outstanding workbook of %s: the summary sheet totals %s but the location sheets total %s (difference %s). Where it comes from: %s. The dashboard uses the location sheets and shows the gap; neither sheet is changed. ',
            to_char((rc->>'as_of')::date, 'DD-Mon-YYYY'), bi.fmt_inr((rc->'summary'->>'gross')::numeric), bi.fmt_inr((rc->>'gross')::numeric), bi.fmt_inr((rc->>'gross')::numeric - (rc->'summary'->>'gross')::numeric),
            (select string_agg(format('%s %s (%s)', coalesce(x->>'sheet', x->>'summary_row'), bi.fmt_inr((x->>'diff_total')::numeric), x->>'status'), '; ')
               from jsonb_array_elements(rc->'rows') x where x->>'status' <> 'matches' or abs((x->>'diff_total')::numeric) >= 1)) end;
      end if;
    elsif q ~ '(receipt|payment|collect)' and q ~ '(not tied|unlinked|not linked|identif|unattribut|location|unallocat)' and q !~ 'invoice' then
      ov := public.bi_call('bm', jsonb_build_object('month', m, 'filters', '{}'::jsonb));
      tot := nullif(ov->'total'->>'collected_current', '')::numeric;
      u := nullif(ov->'finance'->'unallocated'->>('collected_' || replace(left(ov->'finance'->>'receipt_month', 7), '-', '_')), '')::numeric;
      if tot > 0 and u is not null then
        pre := format('%s of %s receipts (to %s) are not yet tied to a location: %s of %s. A receipt is tied through the invoice it settles and, when it is not linked to an invoice, through the paying bank branch; the rest stay unallocated rather than guessed. ',
          bi.fmt_p(u / tot), to_char((ov->'finance'->>'receipt_month')::date, 'Mon YYYY'), to_char((ov->'finance'->>'receipts_through')::date, 'DD-Mon'), bi.fmt_inr(u), bi.fmt_inr(tot));
      end if;
    end if;
  end if;
  if pre <> '' then a := jsonb_set(a, '{answer}', to_jsonb(pre || coalesce(a->>'answer', ''))); end if;
  scope := case when f - 'client_family' = '{}'::jsonb then 'Pan India'$n$]];
  i int;
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'bi_ask3 fragment % not found exactly once', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
  d := pg_get_functiondef('bi.ask_h_collections(date,jsonb,text)'::regprocedure);
  r := array[[$o$format('Outstanding %s as at %s (%s); %s (%s) is over 180 days.',$o$, $n$format('Gross outstanding %s as at %s (%s); %s (%s) is over 180 days.',$n$],
             [$o$else 'net of unadjusted receipts ' || bi.fmt_inr((k->>'net_receivable')::numeric) end$o$,
              $n$else 'the collection and reconciliation target; ' || bi.fmt_inr((k->>'outstanding')::numeric - (k->>'net_receivable')::numeric) || ' of it is money received but not yet linked to an invoice, leaving a net invoice balance of ' || bi.fmt_inr((k->>'net_receivable')::numeric) end$n$]];
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'ask_h_collections fragment % not found exactly once', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
end $do$;

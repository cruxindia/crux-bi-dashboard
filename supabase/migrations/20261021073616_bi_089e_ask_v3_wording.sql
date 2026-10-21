-- Applied to Supabase project via MCP on 20261021073616
-- bi_089e (21-Oct-2026): Ask Crux wording fixes — closed months, corrected premises, Force1 rows dominated by reconciliation
do $do$
declare r record; d text; cur text := null; n int;
begin
  for r in select * from (values
    (1, 'bi.ask_h_shortfall(date,jsonb)',
     $a$         else format('At the current pace, %s of the %s target is projected by month end — a gap of %s cases. Largest contributors (gap, share of the total gap): %s.',
              bi.fmt_n(tot_p), bi.fmt_n(tot_t), bi.fmt_n(tot_t - tot_p), lst) end;$a$,
     $b$         when rem = 0 then format('%s closed at %s of the %s target — %s cases short (%s achieved). Largest shortfalls (gap, share of the total gap): %s.',
              to_char(m, 'Mon YYYY'), bi.fmt_n(tot_p), bi.fmt_n(tot_t), bi.fmt_n(tot_t - tot_p), bi.fmt_p(tot_p / nullif(tot_t, 0)), lst)
         else format('At the current pace, %s of the %s target is projected by month end — a gap of %s cases. Largest contributors (gap, share of the total gap): %s.',
              bi.fmt_n(tot_p), bi.fmt_n(tot_t), bi.fmt_n(tot_t - tot_p), lst) end;$b$),
    (1, 'bi.ask_h_growth(date,jsonb,text)',
     $a$  ans := format('%s cases month to date (tracker of %s) vs %s on the same working day last month (%s): %s %s (%s). Biggest falls: %s. Biggest rises: %s.',$a$,
     $b$  ans := case when q ~ '(lower|down|fall|fell|declin|decreas|less|dropped|drops|behind)' and chg >= 0 then 'Not lower: '
                    when q ~ '(higher|up\M|increas|grow|more than|ahead)' and chg < 0 then 'Not higher: ' else '' end ||
         format('%s cases month to date (tracker of %s) vs %s on the same working day last month (%s): %s %s (%s). Biggest falls: %s. Biggest rises: %s.',$b$),
    (1, 'bi.ask_h_force1(date,jsonb,text)',
     $a$    coalesce(trtxt, 'no earlier months with Force1 case data'), scope_note);$a$,
     $b$    coalesce(trtxt, 'no earlier months with Force1 case data'), scope_note)
    || case when coalesce((t->>'excess_cases')::numeric, 0) > 0.1 * tot_t then
         format(' Read this utilisation with care: Force1 shows %s more cases than the tracker here (%s of the business count), so the figure is capped by the tracker and mainly reflects a reconciliation gap.',
                bi.fmt_n((t->>'excess_cases')::numeric), bi.fmt_p((t->>'excess_cases')::numeric / tot_t)) else '' end;$b$)
  ) v(ord, fn, a, b) order by fn, ord loop
    if cur is distinct from r.fn then
      if cur is not null then execute d; end if;
      cur := r.fn; d := pg_get_functiondef(r.fn::regprocedure);
    end if;
    n := (length(d) - length(replace(d, r.a, ''))) / length(r.a);
    if n <> 1 then raise exception '% patch %: found % times', r.fn, r.ord, n; end if;
    d := replace(d, r.a, r.b);
  end loop;
  if cur is not null then execute d; end if;
end $do$;

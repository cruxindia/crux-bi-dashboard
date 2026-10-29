-- Applied to Supabase project via MCP on 20261029051333
-- bi_097g3 (29-Oct-2026): "who handles / owns" names client-family assignments as such ("BOM clients"), the general row as "all other clients";
-- the target premise answer starts with a plain Yes / No.
do $do$
declare d text; i int; r text[][] := array[
  [$o$select string_agg(format('%s — %s', coalesce(c.label, 'clients without their own manager'), b.manager), '; ' order by b.client_code nulls last) into who_txt$o$,
   $n$select string_agg(format('%s — %s', coalesce(c.label, b.client_family || ' clients', 'all other clients'), b.manager), '; ' order by b.client_code nulls last, b.client_family nulls last) into who_txt$n$],
  [$o$then format('Yes — ahead of the working-day pace: %s cases so far vs %s needed by now (month target %s). '$o$,
   $n$then format('Yes — ahead of the working-day pace: %s cases so far vs %s needed by now (month target %s). '$n$],
  [$o$else format('Not ahead — %s cases so far vs %s needed by now at the working-day pace (month target %s): %s behind. '$o$,
   $n$else format('No — behind the working-day pace: %s cases so far vs %s needed by now (month target %s), %s short. '$n$]];
begin
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  for i in 1 .. array_length(r, 1) loop
    if (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 then raise exception 'bi_ask3 fragment % not found exactly once', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
end $do$;

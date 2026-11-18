-- Applied to Supabase project via MCP on 20261118105443
-- wave 112e (18-Nov-2026): the same-figure check explains why the client-branch counts can differ for a day (potential is rebuilt nightly).
create or replace function pg_temp.patch(p regprocedure, reps text[], expect int[]) returns void language plpgsql as $p$
declare d text := pg_get_functiondef(p); i int; n int;
begin
  insert into bi.fn_backup (fn, def, wave) values (p::text, d, '112e');
  for i in 1 .. array_length(reps, 1) / 2 loop
    n := (length(d) - length(replace(d, reps[2*i-1], ''))) / greatest(length(reps[2*i-1]), 1);
    if n <> expect[i] then raise exception 'patch %: replacement % found % times, expected %', p, i, n, expect[i]; end if;
    d := replace(d, reps[2*i-1], reps[2*i]);
  end loop;
  execute d;
end $p$;
select pg_temp.patch('bi.consistency_check(date,boolean)'::regprocedure, array[
  $r$'Clients with business in the last three months; administrative offices and website-only lists left out.');$r$,
  $r$'Clients with business in the last three months; administrative offices and website-only lists left out. Potential is rebuilt each night (02:15 IST), so after a change of rule or master data the two can differ until the next rebuild.');$r$,
  $r$'Units by type (Business tracker, Ask Crux)', un #> '{summary,active}', 'Potential (Overview, Root cause, Planning)', mp #> '{total,active_branches}'));$r$,
  $r$'Units by type (Business tracker, Ask Crux)', un #> '{summary,active}', 'Potential (Overview, Root cause, Planning)', mp #> '{total,active_branches}'),
          'Active = a Crux case in the last three months. Potential is rebuilt each night (02:15 IST), so after a change of rule or master data the two can differ until the next rebuild.');$r$
], array[1,1]);

-- Applied to Supabase project via MCP on 20261108123431
-- wave 105b: team labels carry people's names in brackets (e.g. "JHARKHAND (Firoz+ Crux)"); those words are hidden from the AI too,
-- unless the word is a known place or a client / zone word.
do $m$
declare d text;
begin
  d := pg_get_functiondef('bi.ai_pii_tokens()'::regprocedure);
  if position('paren' in d) > 0 then return; end if;
  d := replace(d, $a$  select coalesce(jsonb_agg(t order by length(t) desc, t), '[]'::jsonb) from tok$a$,
$a$  , paren as (   -- wave 105b: names inside brackets in team labels
    select distinct w t from (select regexp_split_to_table(upper(regexp_replace(coalesce(substring(label from '\(([^)]*)\)'), ''), '[^A-Za-z ]', ' ', 'g')), '\s+') w from bi.location) x
     where length(w) >= 3 and w not in ('CRUX', 'BRANCH', 'ZONE', 'TEAM')
       and w not in (select upper(rp.place) from bi.ref_place rp)
       and w not in (select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(family, '')), '[^A-Z0-9]+') from bi.client))
  select coalesce(jsonb_agg(t order by length(t) desc, t), '[]'::jsonb) from (select t from tok union select t from paren) u$a$);
  if position('paren as' in d) = 0 then raise exception 'anchor not found'; end if;
  execute d;
end $m$;

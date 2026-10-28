-- Applied to Supabase project via MCP on 20261028145330
-- bi_096j (28-Oct-2026): a person's name inside a location label (e.g. a team named after its manager) is no longer exempt from the AI-provider scrub;
-- label words stay exempt when they are known places or are not part of any mapped person's name.
do $do$
declare d text;
  o text := $o$select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(recon_unit, '') || ' ' || coalesce(zone_group, '') || ' ' || coalesce(region, '')), '[^A-Z0-9]+') w from bi.location$o$;
  n text := $n$select l0.w from (select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(recon_unit, '') || ' ' || coalesce(zone_group, '') || ' ' || coalesce(region, '')), '[^A-Z0-9]+') w from bi.location) l0
                 where l0.w in (select upper(rp.place) from bi.ref_place rp)
                    or l0.w not in (select regexp_split_to_table(upper(regexp_replace(coalesce(bm.manager, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.branch_manager bm
                                    union all select regexp_split_to_table(upper(regexp_replace(coalesce(pr.person, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.person_role pr
                                    union all select regexp_split_to_table(upper(regexp_replace(coalesce(lo.stakeholder, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.location lo)$n$;
begin
  d := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_ai_gateway fragment'; end if;
  execute replace(d, o, n);
end $do$;

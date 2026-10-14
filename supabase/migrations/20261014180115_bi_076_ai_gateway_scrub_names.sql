-- Applied to Supabase project via MCP on 20261014180115
-- bi_076: gateway op 'scrub' — replaces personal-name tokens (Force1 employees, location stakeholders, HR list) with [name]
-- in any text before it is sent to the AI provider. Place, client and zone words and common English/BI words are kept.
do $$
declare d text := pg_get_functiondef('public.bi_ai_gateway(jsonb)'::regprocedure);
        anchor text := $a$  elsif op = 'auth' then$a$;
        addition text := $s$  elsif op = 'scrub' then
    return (with tok as (
        select distinct t from (
          select regexp_split_to_table(upper(regexp_replace(coalesce(name_key, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') t from bi.employee
          union all select regexp_split_to_table(upper(regexp_replace(coalesce(stakeholder, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.location
          union all select regexp_split_to_table(upper(regexp_replace(coalesce(name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+') from bi.workforce_master) z
        where length(t) >= 3
          and t not in (select w from (
                select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(recon_unit, '') || ' ' || coalesce(zone_group, '') || ' ' || coalesce(region, '')), '[^A-Z0-9]+') w from bi.location
                union all select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '') || ' ' || coalesce(family, '') || ' ' || coalesce(product, '')), '[^A-Z0-9]+') from bi.client
                union all select regexp_split_to_table(upper(coalesce(label, '') || ' ' || coalesce(code, '')), '[^A-Z0-9]+') from bi.zone_group) k where w <> '')
          and t not in ('THE','AND','FOR','HOW','WHY','WHAT','WHO','ARE','WAS','MORE','LESS','LAST','NEXT','MONTH','WEEK','YEAR','TEAM','BRANCH','CASE','CASES',
                        'TARGET','DOING','LOWER','HIGHER','BANK','ZONE','TODAY','SALES','TOTAL','REST','NEW','OLD','TOP','LOW','HIGH','BEST','GOOD','WELL','THIS',
                        'THAT','WITH','FROM','LOAN','HOME','CAR','DATA','FIELD','OFFICE','BACK','POINT','POINTS','ALL','ANY','NOT','OUR','YOU','CAN','SHOW','GIVE')),
      rx as (select case when count(*) = 0 then null else '\m(' || string_agg(t, '|' order by length(t) desc) || ')\M' end r from tok)
      select jsonb_build_object(
        'texts', coalesce(jsonb_agg(case when (select r from rx) is null then x else regexp_replace(x, (select r from rx), '[name]', 'gi') end order by o), '[]'::jsonb),
        'replaced', coalesce(sum(case when (select r from rx) is null then 0 else (select count(*) from regexp_matches(x, (select r from rx), 'gi')) end), 0))
      from jsonb_array_elements_text(coalesce(p->'texts', '[]'::jsonb)) with ordinality a(x, o));
$s$;
begin
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then raise exception 'anchor not unique'; end if;
  execute replace(d, anchor, addition || anchor);
end $$;

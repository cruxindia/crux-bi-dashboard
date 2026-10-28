-- Applied to Supabase project via MCP on 20261028122532
-- bi_095a2: Nagpur-area places carry the grouping "NAGPUR (YASH) / NAGPUR (Sudhir) by file" in the reference: the team named in the hint decides
create or replace function bi.loc_of_place(p_place text, p_hint text default null) returns int language sql stable set search_path to 'bi', 'public' as $f$
  with pl as (select coalesce(m.merged_into, m.place) place from bi.ref_place m where upper(m.place) = upper(btrim(p_place)) limit 1),
       g as (select r.place, r.grouping, r.location_id, r.state from pl join bi.ref_place r on upper(r.place) = upper(pl.place))
  select case when g.grouping ~* '^NAGPUR \(YASH\)' and g.location_id is distinct from (select id from bi.location where label = 'NAGPUR (Sudhir)')
              then (select id from bi.location where label = case when coalesce(p_hint, '') ~* 'sudhir' then 'NAGPUR (Sudhir)' else 'NAGPUR (YASH)' end)
              else coalesce(g.location_id, (select s.location_id from bi.ref_state_default s where s.state = g.state)) end
  from g $f$;

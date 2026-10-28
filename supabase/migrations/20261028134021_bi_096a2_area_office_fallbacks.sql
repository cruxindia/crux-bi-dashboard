-- Applied to Supabase project via MCP on 20261028134021
-- bi_096a2: an Area Office that is not a known place as written ("PUNE EAST", "ERNAKULAM", "MALEGAON") is tried without direction / CITY words,
-- then through the branch-name words (towns and localities)
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.place_of_area_office(text,text)'::regprocedure);
  o := $o$select coalesce(r.merged_into, r.place, initcap(d.s)) from d left join bi.ref_place r on upper(r.place) = d.s where d.s is not null$o$;
  n := $n$select coalesce(r.merged_into, r.place, r2.merged_into, r2.place, bi.place_of_branch(d.s), initcap(d.s))
    from d left join bi.ref_place r on upper(r.place) = d.s
    left join bi.ref_place r2 on upper(r2.place) = btrim(regexp_replace(regexp_replace(d.s, '\m(NORTH|SOUTH|EAST|WEST|CENTRAL|CITY)\M', ' ', 'g'), '\s+', ' ', 'g'))
   where d.s is not null$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'fragment'; end if;
  execute replace(d, o, n);
end $do$;

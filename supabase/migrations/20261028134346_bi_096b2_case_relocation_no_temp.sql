-- Applied to Supabase project via MCP on 20261028134346
create or replace function bi.case_relocate_apply(p_run text, p_cases bigint[] default null) returns jsonb
 language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '600s' as $f$
declare v_n int; v_m int; v_b jsonb;
begin
  with x as materialized (select * from bi.case_locate(p_cases)),
  lg as (insert into bi.case_loc_change (case_id, old_location, new_location, basis, place, run)
         select x.case_id, cs.location_id, x.location_id, x.basis, x.place, p_run from x join bi.case_store cs on cs.case_id = x.case_id
          where x.location_id is distinct from cs.location_id and x.location_id is not null
         on conflict (case_id, run) do nothing returning 1),
  up as (update bi.case_store cs set location_id = x.location_id from x
          where cs.case_id = x.case_id and x.location_id is not null and x.location_id is distinct from cs.location_id returning 1)
  select (select count(*) from up), (select count(*) from x), (select jsonb_object_agg(basis, k) from (select basis, count(*) k from x group by 1) z), (select count(*) from lg) * 0
    into v_n, v_m, v_b;
  if p_cases is null or v_n > 0 then
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('case-location-rules', 'case_relocation', 'case_store', p_run, jsonb_build_object('changed', v_n, 'by_basis', v_b));
  end if;
  return jsonb_build_object('changed', v_n, 'cases', v_m, 'by_basis', v_b);
end $f$;

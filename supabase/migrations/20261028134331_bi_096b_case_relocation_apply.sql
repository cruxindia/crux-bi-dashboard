-- Applied to Supabase project via MCP on 20261028134331
-- bi_096b: apply the rule-book case location to bi.case_store.location_id (derived field; the raw area office, branch, pincode and file stay as loaded).
-- Every change is logged in bi.case_loc_change (old and new location, basis) so it can be reviewed or reversed. New uploads use the same rules.
create table if not exists bi.case_loc_change (case_id bigint not null, old_location int, new_location int, basis text, place text, run text not null, changed_at timestamptz not null default now(),
  primary key (case_id, run));
alter table bi.case_loc_change enable row level security;

create or replace function bi.case_relocate_apply(p_run text, p_cases bigint[] default null) returns jsonb
 language plpgsql security definer set search_path to 'bi', 'public' set statement_timeout to '600s' as $f$
declare n int;
begin
  create temp table _cl on commit drop as select * from bi.case_locate(p_cases);
  insert into bi.case_loc_change (case_id, old_location, new_location, basis, place, run)
  select x.case_id, cs.location_id, x.location_id, x.basis, x.place, p_run from _cl x join bi.case_store cs on cs.case_id = x.case_id
   where x.location_id is distinct from cs.location_id and x.location_id is not null
  on conflict (case_id, run) do nothing;
  update bi.case_store cs set location_id = x.location_id from _cl x
   where cs.case_id = x.case_id and x.location_id is not null and x.location_id is distinct from cs.location_id;
  get diagnostics n = row_count;
  if p_cases is null or n > 0 then
    insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('case-location-rules', 'case_relocation', 'case_store', p_run,
      jsonb_build_object('changed', n, 'by_basis', (select jsonb_object_agg(basis, k) from (select basis, count(*) k from _cl group by 1) z)));
  end if;
  return jsonb_build_object('changed', n, 'cases', (select count(*) from _cl));
end $f$;

-- new case uploads: after the file-unit placement, apply the rule book to the batch's cases
do $do$
declare d text; o text := $o$  get diagnostics n = row_count;
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)$o$;
begin
  d := pg_get_functiondef('bi.relocate_cases(bigint)'::regprocedure);
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'relocate_cases fragment'; end if;
  execute replace(d, o, $n$  get diagnostics n = row_count;
  perform bi.case_relocate_apply('batch ' || p_batch, array(select case_id from _n));
  insert into bi.dq_exception(batch_id,source_category,record_key,rule,severity,detail)$n$);
end $do$;

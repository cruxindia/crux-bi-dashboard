-- Applied to Supabase project via MCP on 20261012051334

create index if not exists fact_case_last_batch on bi.fact_case(last_batch);
create index if not exists fact_point_last_batch on bi.fact_point(last_batch);
drop trigger if exists batch_committed on bi.import_batch;

do $$
declare d text; acc text := 'update bi.import_batch set rows_in=rows_in+(r->>''rows_in'')::int, rows_new=rows_new+(r->>''new'')::int,
         rows_changed=rows_changed+(r->>''changed'')::int, rows_unchanged=rows_unchanged+(r->>''unchanged'')::int,
         rows_rejected=rows_rejected+(r->>''rows_in'')::int-(r->>''distinct'')::int where id=p_batch;';
begin
  -- case
  d := pg_get_functiondef('bi.commit_case(bigint)'::regprocedure);
  d := regexp_replace(d, 'update bi\.import_batch set status=''committed''.*?where id=p_batch;', acc || ' perform bi.relocate_cases(p_batch);');
  d := replace(d, 'and c.last_batch=p_batch;', 'and c.last_batch=p_batch and c.updated_at=now();');
  if d !~ 'perform bi.relocate_cases' or d ~ 'status=''committed''' then raise exception 'commit_case patch failed'; end if;
  execute d;
  -- point
  d := pg_get_functiondef('bi.commit_point(bigint)'::regprocedure);
  d := regexp_replace(d, 'update bi\.import_batch set status=''committed''.*?where id=p_batch;', acc);
  d := replace(d, 'and p.last_batch=p_batch;', 'and p.last_batch=p_batch and p.updated_at=now();');
  d := replace(d, 'where last_batch=p_batch and point_type is not null', 'where last_batch=p_batch and updated_at=now() and point_type is not null');
  if d ~ 'status=''committed''' then raise exception 'commit_point patch failed'; end if;
  execute d;
  -- relocation limited to rows touched in this transaction
  d := pg_get_functiondef('bi.relocate_cases(bigint)'::regprocedure);
  d := replace(d, 'and c.last_batch=p_batch;', 'and c.last_batch=p_batch and c.updated_at=now();');
  d := replace(d, 'where c.last_batch=p_batch group by', 'where c.last_batch=p_batch and c.updated_at=now() group by');
  execute d;
  -- ingest: add finalize
  d := pg_get_functiondef('public.bi_ingest(text,text,jsonb)'::regprocedure);
  d := replace(d, 'elsif p_action = ''reject'' then',
    'elsif p_action = ''finalize'' then
    v_id := (p_payload->>''batch_id'')::bigint;
    update bi.import_batch set status=''committed'', committed_at=now() where id=v_id and status=''staged'' and source_category in (''case'',''point'');
    insert into bi.audit_log(actor,action,entity,entity_key) values (v_actor,''import_finalize'',''import_batch'',v_id::text);
    return (select to_jsonb(b) - ''file_hash'' from bi.import_batch b where id=v_id);
  elsif p_action = ''reject'' then');
  execute d;
end $$;
-- a duplicate-file re-upload of case/point must still be detectable before finalize
select 1;


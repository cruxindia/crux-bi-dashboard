-- Applied to Supabase project via MCP on 20261022042327
do $do$
declare d text; o text[]; n text[]; i int;
begin
  d := pg_get_functiondef('bi.fin_ingest_as(text,text,jsonb)'::regprocedure);
  o := array[$o0$declare u bi.fin_upload; v_id bigint;$o0$,
$o1$      return jsonb_build_object('duplicate', true, 'upload_id', u.id, 'status', u.status, 'committed_at', u.committed_at);
    end if;$o1$,
$o2$coalesce(p->'controls', '{}'::jsonb)$o2$,
$o3$    if (select count(*) from bi.fin_part where upload_id = u.id) = 0 then raise exception 'nothing staged'; end if;$o3$];
  n := array[$n0$declare u bi.fin_upload; u2 bi.fin_upload; v_h text; v_id bigint;$n0$,
$n1$      return jsonb_build_object('duplicate', true, 'upload_id', u.id, 'status', u.status, 'committed_at', u.committed_at);
    end if;
    -- same rows under a different file (re-saved or re-downloaded copy): nothing to import
    if nullif(p->>'content_sha256', '') is not null then
      select * into u2 from bi.fin_upload x where x.kind = p->>'kind' and x.status in ('committed', 'superseded') and x.controls->>'content_sha256' = p->>'content_sha256'
       order by x.id desc limit 1;
      if found then
        return jsonb_build_object('duplicate', true, 'duplicate_content', true, 'upload_id', u2.id, 'status', u2.status, 'committed_at', u2.committed_at,
          'message', 'This workbook has exactly the same rows as ' || u2.file_name || ' (upload ' || u2.id || '); nothing was imported.');
      end if;
    end if;$n1$,
$n2$coalesce(p->'controls', '{}'::jsonb) || case when nullif(p->>'content_sha256', '') is not null then jsonb_build_object('content_sha256', p->>'content_sha256') else '{}'::jsonb end$n2$,
$n3$    if (select count(*) from bi.fin_part where upload_id = u.id) = 0 then raise exception 'nothing staged'; end if;
    -- server-side content hash of the staged rows; identical content to an earlier upload is never committed twice
    v_h := (select encode(extensions.digest(string_agg(fp.sheet || '|' || fp.seq || '|' || encode(extensions.digest(fp.rows::text, 'sha256'), 'hex'), ';' order by fp.sheet collate "C", fp.seq), 'sha256'), 'hex')
            from bi.fin_part fp where fp.upload_id = u.id);
    select * into u2 from bi.fin_upload x where x.kind = u.kind and x.status in ('committed', 'superseded') and x.id <> u.id and x.controls->>'content_sha256' = v_h order by x.id desc limit 1;
    if found then
      update bi.fin_upload set status = 'rejected', notes = 'identical rows to upload ' || u2.id || ' (' || u2.file_name || ')', controls = controls || jsonb_build_object('content_sha256', v_h) where id = u.id;
      insert into bi.audit_log (actor, action, entity, entity_key, detail) values (p_actor, 'fin_duplicate_content', 'fin_upload', u.id::text, jsonb_build_object('same_as', u2.id));
      return jsonb_build_object('ok', false, 'duplicate_content', true, 'upload_id', u.id, 'same_as', u2.id, 'status', 'rejected');
    end if;
    update bi.fin_upload set controls = controls || jsonb_build_object('content_sha256', v_h) where id = u.id;$n3$];
  for i in 1 .. array_length(o, 1) loop
    if position(o[i] in d) = 0 then raise exception 'fin_ingest fragment % not found', i; end if;
    d := replace(d, o[i], n[i]);
  end loop;
  execute d;
end $do$;
update bi.fin_upload u set controls = u.controls || jsonb_build_object('content_sha256',
  (select encode(extensions.digest(string_agg(fp.sheet || '|' || fp.seq || '|' || encode(extensions.digest(fp.rows::text, 'sha256'), 'hex'), ';' order by fp.sheet collate "C", fp.seq), 'sha256'), 'hex')
   from bi.fin_part fp where fp.upload_id = u.id))
where u.status in ('committed', 'superseded') and u.controls->>'content_sha256' is null;


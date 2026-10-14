-- Applied to Supabase project via MCP on 20261014161956
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  if position('''run_relabel''' in d) = 0 then
    d2 := replace(d, '  elsif op = ''run_status'' then', '  elsif op = ''run_relabel'' then
    -- admin correction of a mislabelled job record (kept, never removed)
    if coalesce(trim(p->>''note''), '''') = '''' then raise exception ''A note is required''; end if;
    update bi.job_run set job = coalesce(nullif(p->>''job'', ''''), job), summary = left(coalesce(summary, '''') || '' [Corrected: '' || (p->>''note'') || '']'', 2000)
     where id = any (array(select jsonb_array_elements_text(p->''run_ids'')::bigint));
    get diagnostics n_upd = row_count;
    insert into bi.audit_log(actor, action, entity, detail) values (p_actor, ''branch_run_relabel'', ''job_run'', p - ''admin_key'');
    return jsonb_build_object(''ok'', true, ''rows'', n_upd);
  elsif op = ''run_status'' then');
    if d2 = d then raise exception 'anchor'; end if;
    execute d2;
  end if;
end $$;

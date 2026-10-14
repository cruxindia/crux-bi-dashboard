-- Applied to Supabase project via MCP on 20261014142230
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  d2 := replace(d, 'select v_fam, b.branch_uid, b.location_id, ''duplicate_candidate''', 'select distinct on (b.branch_uid) v_fam, b.branch_uid, b.location_id, ''duplicate_candidate''');
  d2 := replace(d2, 'and similarity(a.branch_name, b.branch_name) >= 0.85 and coalesce(a.branch_type, '''') = coalesce(b.branch_type, '''')',
                    'and similarity(a.branch_name, b.branch_name) >= 0.85 and coalesce(a.branch_type, '''') = coalesce(b.branch_type, '''')
    order by b.branch_uid, similarity(a.branch_name, b.branch_name) desc');
  -- quiet skip: repeated cron ticks for an already-processed source version do not add rows
  d2 := replace(d2, 'if not coalesce((p->>''force'')::boolean, false) and exists (select 1 from bi.job_run where job = p->>''job'' and status = ''succeeded''',
    'if not coalesce((p->>''force'')::boolean, false) and exists (select 1 from bi.job_run where job = p->>''job'' and status in (''succeeded'', ''skipped'')
         and source_version = p->>''source_version'' and started_at > now() - interval ''20 hours'') then
      return jsonb_build_object(''skip'', true, ''quiet'', true);
    end if;
    if not coalesce((p->>''force'')::boolean, false) and exists (select 1 from bi.job_run where job = p->>''job'' and status = ''succeeded''');
  if position('distinct on (b.branch_uid)' in d2) = 0 or position('''quiet''' in d2) = 0 then raise exception 'patch anchor missing'; end if;
  execute d2;
end $$;

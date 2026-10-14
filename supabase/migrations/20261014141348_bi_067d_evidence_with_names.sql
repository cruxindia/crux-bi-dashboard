-- Applied to Supabase project via MCP on 20261014141348
create or replace function bi.case_branch_evidence()
returns jsonb language sql stable security definer set search_path = bi, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('family', fam, 'code', code, 'location_id', location_id, 'name', bname, 'n', n, 'last', last_m)), '[]')
  from (select coalesce(c.family, s.client_code) fam, bi.norm_code(s.branch_code) code, s.location_id, d.val bname, count(*) n, max(s.received_month) last_m
        from bi.case_store s left join bi.client c on c.code = s.client_code left join bi.dim d on d.id = s.branch_id
        where bi.norm_code(s.branch_code) is not null group by 1, 2, 3, 4) x $$;
do $$
declare d text; d2 text;
begin
  d := pg_get_functiondef('bi.branch_admin(text,jsonb)'::regprocedure);
  d2 := regexp_replace(d, 'elsif op = ''evidence'' then.*?group by 1, 2, 3\) x\);', 'elsif op = ''evidence'' then
    return bi.case_branch_evidence();', 's');
  if d2 = d then raise exception 'evidence anchor not found'; end if;
  execute d2;
end $$;

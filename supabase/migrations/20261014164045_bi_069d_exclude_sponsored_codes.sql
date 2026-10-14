-- Applied to Supabase project via MCP on 20261014164045
-- IFSC codes under a sponsor bank's prefix but with a non-numeric branch part belong to regional rural banks,
-- co-operative sub-members, collection accounts or administrative units — not the client's own branches.
-- Bank of Baroda is the exception (its own branch codes are alphabetic). They are kept as evidence, marked ineligible.
create or replace function bi.branch_exclude_sponsored()
returns jsonb language plpgsql security definer set search_path = bi, public as $$
declare n int; r int;
begin
  with x as (
    update bi.client_branch_master m set status = 'ineligible', verification_status = 'excluded_not_client',
      research_notes = 'IFSC issued under the client''s code to another institution or a non-branch account (regional rural bank, co-operative sub-member, collection or office code); not part of the client''s own branch network.',
      updated_at = now()
    where m.source_type = 'rbi_ifsc_directory' and m.client_family <> 'BOB' and m.status = 'active' and substr(m.ifsc, 6) !~ '^[0-9]{6}$'
    returning m.branch_uid, m.client_family, m.branch_name),
  h as (insert into bi.client_branch_history(branch_uid, client_family, change_type, old, new)
        select branch_uid, client_family, 'status_changed', jsonb_build_object('status', 'active'), jsonb_build_object('status', 'ineligible', 'reason', 'sponsored or non-branch IFSC') from x returning 1)
  select count(*) into n from h;
  update bi.branch_review b set status = 'dismissed', resolved_at = now(), resolved_by = 'rule:sponsored-ifsc', resolution = 'Branch excluded: IFSC belongs to another institution or a non-branch account.'
   from bi.client_branch_master m where m.branch_uid = b.branch_uid and m.status = 'ineligible' and b.status = 'open';
  get diagnostics r = row_count;
  insert into bi.audit_log(actor, action, entity, detail) values ('rule:sponsored-ifsc', 'branch_exclude_sponsored', 'client_branch_master', jsonb_build_object('excluded', n, 'reviews_closed', r));
  return jsonb_build_object('excluded', n, 'reviews_closed', r);
end $$;
select bi.branch_exclude_sponsored();

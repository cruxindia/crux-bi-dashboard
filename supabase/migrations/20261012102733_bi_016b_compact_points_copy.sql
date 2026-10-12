-- Applied to Supabase project via MCP on 20261012102733

insert into bi.point_store(point_id,case_id,branch_id,client_code_raw,point_type_id,created_by_id,created_at,assign_to_id,status,verified_by_id,completed_by_id,
  assigned_at,field_reviewed_at,completed_at,pincode,has_address,file_group,recon_unit,row_hash,last_batch)
select p.point_id, p.case_id, b.id, p.client_code_raw, t.id, cb.id, p.created_at, a.id, p.status, v.id, cp.id,
  p.assigned_at, p.field_reviewed_at, p.completed_at, case when p.pincode ~ '^\d{6}$' then p.pincode::int end, p.has_address,
  p.file_group, p.recon_unit, hashtextextended(p.row_hash,0), p.last_batch
from bi.fact_point p
left join bi.dim b on b.kind='branch' and b.val=p.branch
left join bi.dim t on t.kind='point_type' and t.val=p.point_type
left join bi.dim cb on cb.kind='emp' and cb.val=p.created_by
left join bi.dim a on a.kind='emp' and a.val=p.assign_to
left join bi.dim v on v.kind='emp' and v.val=p.verified_by
left join bi.dim cp on cp.kind='emp' and cp.val=p.completed_by;


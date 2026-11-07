-- Applied to Supabase project via MCP on 20261107104945
-- Wave 100 (7-Nov-2026), OD-010 decided by Claude on the owner's delegation ("I trust your decisions", 7-Nov 16:03 IST).
-- In districts shared by two Crux teams, a client's branch belongs to the team that handles that client in the October-2026
-- tracker; where both teams handle the client, the team with the larger October target. Families neither team handles stay
-- without a team (counted under the zone). Additive: client_branch_master is NOT changed, so case / point location rules and
-- the identity checks are unaffected; the rule is read by coverage and business-potential views only.
create table if not exists bi.territory_family_rule (
  id bigserial primary key,
  zone_group text not null,
  district_like text,                 -- ILIKE pattern on client_branch_master.district; null = the whole zone
  client_family text not null,
  location_id int not null references bi.location(id),
  basis text not null,
  decided_by text not null,
  decided_at timestamptz not null default now(),
  effective_from date not null default current_date,
  effective_to date,
  note text);
alter table bi.territory_family_rule enable row level security;
create unique index if not exists territory_family_rule_open_uq on bi.territory_family_rule (zone_group, coalesce(district_like, '*'), client_family) where effective_to is null;

insert into bi.territory_family_rule (zone_group, district_like, client_family, location_id, basis, decided_by, note)
select v.zg, v.dl, v.fam, v.loc, v.basis, 'claude (owner-delegated 7-Nov-2026)', v.note
from (values
  ('REST_MAHA', '%NAGPUR%', 'SBI',    30, 'tracker_team_client', 'Oct-26 tracker: SBI handled only by NAGPUR (YASH) (target 3,500)'),
  ('REST_MAHA', '%NAGPUR%', 'BOM',    31, 'tracker_larger_target', 'Oct-26 tracker: BOM handled by both teams; NAGPUR (Sudhir) BOM target 450 > NAGPUR (YASH) BOM MSME target 145'),
  ('REST_MAHA', '%NAGPUR%', 'IDBI',   31, 'tracker_team_client', 'Oct-26 tracker: IDBI handled only by NAGPUR (Sudhir) (target 160)'),
  ('REST_MAHA', '%NAGPUR%', 'BOI',    31, 'tracker_team_client', 'Oct-26 tracker: BOI handled only by NAGPUR (Sudhir) (target 10)'),
  ('REST_MAHA', '%NAGPUR%', 'SVC',    31, 'tracker_team_client', 'Oct-26 tracker: SVC handled only by NAGPUR (Sudhir) (target 20)'),
  ('REST_MAHA', '%NAGPUR%', 'LICHFL', 31, 'tracker_team_client', 'Oct-26 tracker: LICHFL handled only by NAGPUR (Sudhir) (target 40)'),
  ('REST_MAHA', '%NAGPUR%', 'CANFH',  31, 'tracker_team_client', 'Oct-26 tracker: CANFH handled only by NAGPUR (Sudhir) (target 10)'),
  ('LUCKNOW',   null,       'SBI',    22, 'tracker_larger_target', 'Oct-26 tracker: SBI handled by both teams; Lucknow/ROUP - (Mukesh Yadav) target 2,500 > Lucknow/ROUP - Branch 250'),
  ('LUCKNOW',   null,       'BOM',    21, 'tracker_larger_target', 'Oct-26 tracker: BOM handled by both teams; Lucknow/ROUP - Branch target 170 > (Mukesh Yadav) 125'),
  ('LUCKNOW',   null,       'BOI',    21, 'tracker_team_client', 'Oct-26 tracker: BOI handled only by Lucknow/ROUP - Branch (target 50)'),
  ('LUCKNOW',   null,       'IDBI',   21, 'tracker_team_client', 'Oct-26 tracker: IDBI handled only by Lucknow/ROUP - Branch (target 20)')
) v(zg, dl, fam, loc, basis, note)
on conflict do nothing;

create or replace view bi.v_branch_family_rule as
select b.branch_uid, r.location_id, r.id rule_id
from bi.client_branch_master b
join lateral (select r.location_id, r.id from bi.territory_family_rule r
               where r.effective_to is null and r.zone_group = b.zone_group and r.client_family = b.client_family
                 and (r.district_like is null or b.district ilike r.district_like)
               order by (r.district_like is null), r.id limit 1) r on true
where b.location_id is null;
revoke all on bi.v_branch_family_rule from anon, authenticated;

insert into bi.audit_log(actor, action, entity, entity_key, detail)
select 'claude (owner-delegated 7-Nov-2026)', 'territory_rule', 'territory_family_rule', 'OD-010',
       jsonb_build_object('rules', (select count(*) from bi.territory_family_rule where effective_to is null),
                          'branches_given_a_team', (select count(*) from bi.v_branch_family_rule),
                          'rule', 'shared district: team that handles the client in the Oct-26 tracker; both teams -> larger Oct target; neither -> no team (zone only)',
                          'client_branch_master_changed', false);


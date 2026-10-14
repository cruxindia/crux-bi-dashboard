-- Applied to Supabase project via MCP on 20261013071830

create table if not exists bi.client_branch_master (
  client_code text not null, branch_code text not null, branch_name text, state text, city text, location_id int references bi.location(id),
  status text not null default 'active' check (status in ('active','closed','ineligible')), opened_on date, closed_on date,
  source text not null, verified_on date not null, confidence text not null default 'medium' check (confidence in ('high','medium','low')),
  updated_by text, updated_at timestamptz default now(), primary key (client_code, branch_code));
alter table bi.client_branch_master enable row level security;

create or replace function bi.api_branches(f jsonb) returns jsonb
language sql stable security definer set search_path=bi,public as $$
with cov as (select recon_unit, received_month m from bi.case_store where received_month < date_trunc('month', now() at time zone 'Asia/Kolkata') group by 1,2),
covr as (select recon_unit, m, row_number() over (partition by recon_unit order by m desc) rn, count(*) over (partition by recon_unit) n_cov from cov),
br as (select c.client_code, coalesce(nullif(c.branch_code,''), d.val) bkey, max(d.val) bname, max(c.branch_code) bcode, c.recon_unit,
         mode() within group (order by c.location_id) location_id, c.received_month m, count(*) n
       from bi.case_store c left join bi.dim d on d.id=c.branch_id
       where c.received_month < date_trunc('month', now() at time zone 'Asia/Kolkata')
       group by c.client_code, coalesce(nullif(c.branch_code,''), d.val), c.recon_unit, c.received_month),
grid as (select b.client_code, b.bkey, b.recon_unit, v.m, v.rn, v.n_cov, coalesce(x.n,0) n
         from (select distinct client_code, bkey, recon_unit from br) b join covr v on v.recon_unit=b.recon_unit
         left join br x on x.client_code=b.client_code and x.bkey=b.bkey and x.recon_unit=b.recon_unit and x.m=v.m),
s as (select g.client_code, g.bkey, g.recon_unit, max(g.n_cov) n_cov,
        sum(n) filter (where rn<=3) l3, sum(n) filter (where rn between 4 and 6) p3, sum(n) filter (where rn<=2) l2,
        sum(n) filter (where rn=1) last1, sum(n) filter (where rn between 2 and 3) prev2, sum(n) total,
        min(m) filter (where n>0) first_seen, max(m) filter (where n>0) last_seen, max(m) latest_cov,
        (select max(m) from covr c2 where c2.recon_unit=g.recon_unit and c2.rn=2) cov2
      from grid g group by 1,2,3),
meta as (select client_code, bkey, recon_unit, max(bname) bname, max(bcode) bcode, mode() within group (order by location_id) location_id from br group by 1,2,3),
cls as (select s.*, m.bname, m.bcode, m.location_id,
  case when s.n_cov < 6 or s.total < 3 then 'insufficient_data'
       when s.first_seen >= s.cov2 then 'new'
       when s.l2 = 0 then 'dormant'
       when s.last1 > 0 and s.prev2 = 0 and s.total - s.l3 > 0 then 'reactivated'
       when s.l3 >= s.p3*1.2 and s.l3 - s.p3 >= 3 then 'growing'
       when s.l3 <= s.p3*0.7 and s.p3 - s.l3 >= 3 then 'losing_traction'
       else 'stable' end status
  from s join meta m using (client_code, bkey, recon_unit)),
peer as (select client_code, recon_unit, count(*) n_peer, percentile_cont(0.5) within group (order by l3/3.0) med
         from cls where status in ('stable','growing','losing_traction') group by 1,2),
f2 as (select c.*, p.n_peer, p.med, l.label location, l.stakeholder,
  case when c.status in ('stable','losing_traction') and p.n_peer >= 5 then greatest(0, p.med - c.l3/3.0) end opp_monthly,
  case when p.n_peer >= 15 and c.n_cov >= 6 then 'medium' when p.n_peer >= 5 then 'low' else 'none' end conf
  from cls c left join peer p using (client_code, recon_unit) left join bi.location l on l.id=c.location_id
  where bi.loc_ok(c.location_id, c.recon_unit, f) and bi.fam_ok(c.client_code, f)),
pri as (select *, case status when 'losing_traction' then (p3 - l3)/3.0 when 'dormant' then (total - l3)::numeric/greatest(n_cov-3,1) else coalesce(opp_monthly,0) end impact from f2)
select jsonb_build_object(
 'as_of', 'complete months only; current month excluded',
 'summary', (select jsonb_object_agg(status, n) from (select status, count(*) n from f2 group by 1) x),
 'by_client', (select jsonb_agg(x) from (select client_code, count(*) branches_seen, count(*) filter (where status not in ('dormant','insufficient_data')) active,
     count(*) filter (where status='dormant') dormant, count(*) filter (where status='losing_traction') losing, count(*) filter (where status='growing') growing,
     (select count(*) from bi.client_branch_master m where m.client_code=f2.client_code and m.status='active') verified_total
     from f2 group by client_code order by 2 desc) x),
 'priority', (select jsonb_agg(x) from (select client_code client, bname branch, bcode branch_code, recon_unit, location, stakeholder, status,
     l3 last3m, p3 prior3m, last_seen, first_seen, n_peer peers, round(med::numeric,1) peer_median_monthly, round(opp_monthly::numeric,1) est_opportunity_monthly, conf confidence,
     round(impact::numeric,1) priority_cases_per_month,
     case status when 'losing_traction' then 'Review with branch/client: volume down vs prior 3 months'
                 when 'dormant' then 'Recovery call: no cases in last 2 covered months'
                 when 'stable' then case when opp_monthly > 0 then 'Growth: below peer median for same client & location group' end
                 when 'reactivated' then 'Secure: branch resumed after a gap' when 'new' then 'Onboard: new branch, monitor ramp-up' end action
     from pri where status in ('losing_traction','dormant','stable','reactivated','new') and impact > 0 order by impact desc limit 300) x),
 'method', jsonb_build_object(
   'window','Last 3 complete covered months (L3) vs prior 3 (P3) of the branch''s location group; months without Case Wise coverage ignored',
   'rules','insufficient_data: <6 covered months or <3 cases; new: first case in last 2 covered months; dormant: 0 in last 2; reactivated: >0 in latest after 0 in previous 2; growing: L3 ≥ 1.2×P3 and +3; losing_traction: L3 ≤ 0.7×P3 and −3; else stable',
   'opportunity','Estimated opportunity = peer median monthly cases (same client, same location group, active branches) − branch L3 average; shown only with ≥5 peers. Estimate, not confirmed leakage.',
   'universe','Branches seen in Force1 Case Wise only. Never-activated and closed branches and coverage % need the verified client branch master (bi.client_branch_master).'));
$$;

do $$ declare d text; begin
  d := pg_get_functiondef('public.bi_call(text,jsonb)'::regprocedure);
  d := replace(d, $a$when 'force1' then bi.api_force1(m,f)$a$, $a$when 'force1' then bi.api_force1(m,f)
      when 'branches' then bi.api_branches(f)$a$);
  if position('api_branches' in d)=0 then raise exception 'patch failed'; end if;
  execute d;
end $$;
grant execute on function public.bi_call(text, jsonb) to anon, authenticated;


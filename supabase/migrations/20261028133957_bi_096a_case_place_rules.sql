-- Applied to Supabase project via MCP on 20261028133957
-- bi_096a (28-Oct-2026): case location by the case-mapping rule book (27-Oct "Case mapping logic and method"): a case counts where it is,
-- not where its file is. Area Office (cleaned) -> office learned for the client branch (60 %+) -> place named in the branch name -> the branch's
-- customers' area (2+ cases, 60 %+) -> residence pincode (longest prefix) -> the file's usual location. Nagpur-area places follow the Nagpur
-- team whose file holds the case. Learned pincode rules (5, 6) are not used (the rule book says they rarely decide).
create or replace function bi.place_of_area_office(p text, p_client text default null) returns text language sql stable set search_path to 'bi', 'public' as $f$
  with a as (select btrim(regexp_replace(upper(coalesce(p, '')), '[._()]', ' ', 'g')) s),
  b as (select case when s in ('', '-', 'NA', 'N/A', 'NULL', 'NONE', 'NIL') then null
                    when s ~ '\m(SBI|STATE BANK|BANK|BOM|IDBI|LICHFL|LIC|SVC|CANARA|CANB|CANFH|BOI|AXIS|AXISF|HDFC|ICICI|PNB|UNION|BARODA|KOTAK)\M' then null
                    when p_client is not null and s = upper(btrim(p_client)) then null else s end s from a),
  c as (select btrim(regexp_replace(regexp_replace(regexp_replace(s,
           '\m(AREA OFFICE|ADMINISTRATIVE OFFICE|ADMIN OFFICE|REGIONAL BUSINESS OFFICE|ZONAL OFFICE|LOCAL HEAD OFFICE|LHO|AREA|AO|ZONE|ZO|RBO|REGION|OFFICE|CIRCLE)\M', ' ', 'g'),
           '[^A-Z ]', ' ', 'g'), '\s+', ' ', 'g')) s from b),
  d as (select case when s ~ '^((NORTH|SOUTH|EAST|WEST|CENTRAL) ?)+$' or s = '' then null
                    else coalesce((select v from (values ('VIJAYWADA', 'VIJAYAWADA'), ('BANGLORE', 'BENGALURU'), ('BANGALORE', 'BENGALURU'), ('BHUBANESHWAR', 'BHUBANESWAR'),
                       ('BHUVANESHWAR', 'BHUBANESWAR'), ('AURANGABAD', 'CHHATRAPATI SAMBHAJINAGAR'), ('GURGAON', 'GURUGRAM'), ('BOMBAY', 'MUMBAI'), ('MADRAS', 'CHENNAI'),
                       ('CALCUTTA', 'KOLKATA'), ('GUJARAT', 'AHMEDABAD'), ('KARNATAKA', 'BENGALURU'), ('TELANGANA', 'HYDERABAD'), ('ODISHA', 'BHUBANESWAR'),
                       ('MADHYA PRADESH', 'BHOPAL'), ('CHHATTISGARH', 'RAIPUR'), ('UTTAR PRADESH', 'LUCKNOW'), ('BIHAR', 'PATNA'), ('ASSAM', 'GUWAHATI'),
                       ('PUNJAB', 'CHANDIGARH'), ('HARYANA', 'CHANDIGARH'), ('TAMIL NADU', 'CHENNAI'), ('KERALA', 'THIRUVANANTHAPURAM'), ('RAJASTHAN', 'JAIPUR'),
                       ('WEST BENGAL', 'KOLKATA'), ('MAHARASHTRA', 'MUMBAI')) m(k, v) where m.k = c.s), c.s) end s from c)
  select coalesce(r.merged_into, r.place, initcap(d.s)) from d left join bi.ref_place r on upper(r.place) = d.s where d.s is not null $f$;

-- residence pincode -> place (longest prefix 6 -> 2; a 2-digit match gives a state)
create or replace function bi.place_of_pin(p text) returns text language sql stable set search_path to 'bi', 'public' as $f$
  select coalesce(r.place, r.state) from bi.ref_pin_prefix r
   where (substring(p from '\d{6}')) like r.prefix || '%' and length(r.prefix) between 2 and 6
   order by length(r.prefix) desc limit 1 $f$;

-- location of every case (or the given cases) by the rule book; the file's usual location is the last resort
create or replace function bi.case_locate(p_cases bigint[] default null)
 returns table(case_id bigint, location_id int, place text, basis text) language sql stable security definer set search_path to 'bi', 'public' as $f$
  with c as materialized (
    select cs.case_id, cs.client_code, cs.branch_id, cs.file_group, cs.recon_unit, cs.area_office_id
      from bi.case_store cs where p_cases is null or cs.case_id = any (p_cases)),
  ak as materialized (select k.area_office_id, k.client_code, bi.place_of_area_office((select val from bi.dim where id = k.area_office_id), k.client_code) ao_raw
                        from (select distinct c.area_office_id, c.client_code from c where c.area_office_id is not null) k),
  aol as materialized (select a.area_office_id, a.client_code, a.ao_raw, bi.loc_of_place(a.ao_raw, 'x') l from ak a where a.ao_raw is not null),
  br as materialized (select distinct c.branch_id from c where c.branch_id is not null),
  brw as materialized (select br.branch_id, bi.place_of_branch((select val from bi.dim where id = br.branch_id)) pl from br),
  -- residence pincode of the case (residence verification point first, else any point with a pincode)
  pin as materialized (
    select distinct on (p.case_id) p.case_id, p.pincode::text pin
      from bi.point_store p join c on c.case_id = p.case_id
     where p.pincode between 100000 and 999999
     order by p.case_id, (p.point_type_id is not distinct from (select d.id from bi.dim d where d.kind = 'point_type' and lower(d.val) = 'residence verification' limit 1)) desc, p.point_id),
  pinp as materialized (select distinct pin.pin, bi.place_of_pin(pin.pin) pl from pin),
  -- rule 2: office learned for the client branch (60 %+ of its office-bearing cases)
  bo as materialized (
    select x.branch_id, x.ao_raw from (
      select c.branch_id, c.ao_raw, count(*) n, sum(count(*)) over (partition by c.branch_id) t,
             row_number() over (partition by c.branch_id order by count(*) desc) rk
        from (select c.branch_id, aol.ao_raw from c join aol on aol.area_office_id = c.area_office_id and aol.client_code = c.client_code and aol.l is not null) c
       where c.branch_id is not null group by 1, 2) x where x.rk = 1 and x.n >= 0.6 * x.t),
  -- rule 4: the branch's customers' area (2+ cases, 60 %+ in one place)
  ba as materialized (
    select x.branch_id, x.pl from (
      select c.branch_id, pp.pl, count(*) n, sum(count(*)) over (partition by c.branch_id) t,
             row_number() over (partition by c.branch_id order by count(*) desc) rk
        from c join pin on pin.case_id = c.case_id join pinp pp on pp.pin = pin.pin where c.branch_id is not null and pp.pl is not null group by 1, 2) x
     where x.rk = 1 and x.n >= 2 and x.n >= 0.6 * x.t),
  r as (
    select c.case_id, c.file_group, c.recon_unit,
           case when aol.l is not null then aol.ao_raw end p1, bo.ao_raw p2, brw.pl p3, ba.pl p4, pp.pl p7
      from c left join aol on aol.area_office_id = c.area_office_id and aol.client_code = c.client_code left join bo on bo.branch_id = c.branch_id left join brw on brw.branch_id = c.branch_id
      left join ba on ba.branch_id = c.branch_id left join pin on pin.case_id = c.case_id left join pinp pp on pp.pin = pin.pin),
  pk as materialized (select distinct v.pl, r.file_group from r cross join lateral (values (r.p1), (r.p2), (r.p3), (r.p4), (r.p7)) v(pl) where v.pl is not null),
  pkl as materialized (select pk.pl, pk.file_group, coalesce(bi.loc_of_place(pk.pl, pk.file_group), (select s.location_id from bi.ref_state_default s where upper(s.state) = upper(pk.pl))) l from pk),
  ud as materialized (select l.recon_unit, min(l.id) id from bi.location l where l.is_unit_default group by 1)
  select r.case_id, coalesce(l1.l, l2.l, l3.l, l4.l, l7.l, ud.id),
         case when l1.l is not null then r.p1 when l2.l is not null then r.p2 when l3.l is not null then r.p3 when l4.l is not null then r.p4 when l7.l is not null then r.p7 end,
         case when l1.l is not null then 'area office' when l2.l is not null then 'office learned for the branch' when l3.l is not null then 'place in the branch name'
              when l4.l is not null then 'branch customers'' area' when l7.l is not null then 'pincode table' when ud.id is not null then 'file''s usual location' else 'not identified' end
    from r
    left join pkl l1 on l1.pl = r.p1 and l1.file_group is not distinct from r.file_group
    left join pkl l2 on l2.pl = r.p2 and l2.file_group is not distinct from r.file_group
    left join pkl l3 on l3.pl = r.p3 and l3.file_group is not distinct from r.file_group
    left join pkl l4 on l4.pl = r.p4 and l4.file_group is not distinct from r.file_group
    left join pkl l7 on l7.pl = r.p7 and l7.file_group is not distinct from r.file_group
    left join ud on ud.recon_unit = r.recon_unit $f$;

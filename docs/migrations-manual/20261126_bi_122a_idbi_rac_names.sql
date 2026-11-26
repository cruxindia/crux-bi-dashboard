-- Wave 122a (26-Nov-2026): IDBI Retail Asset Centres counted as RAC.
-- Change request (Crux operations, 26-Nov, with the IDBI RAC list "IDBI LIC ACTIVE INACTIVE NOV 2026"): "Mumbai we have 10 RACs, only 1 RAC is shown".
-- Checked: valid. The client branch master has the Mumbai RACs, but 41 IDBI rows are named "RETAIL ASSET(S) [CENTRE|CENTER] <place>"
-- (e.g. RETAIL ASSET THANE 000821, 671 cases in 3 months) and bi.unit_type only recognised the abbreviation "RAC", so they were typed "Branch".
-- Three more IDBI RACs carry only the place name (SALEM 008050, SATARA 008027, TIRUCHIRAPALLI 008033 — RAC code series 0080xx, all three on the
-- IDBI RAC list): typed RAC through a small override table. Ten RACs on the list have no code of their own (public IFSC directories list only the
-- branch at that place, e.g. Gachibowli IBKL0000432, Frazer Town IBKL0002310, Esplanade IBKL0001270): the RAC works from that branch, so the branch
-- row is typed RAC (Bidadi, Frazer Town, Chandigarh, Karol Bagh, Rajouri Garden, Gachibowli, Brabourne Road, Esplanade, Howrah, Moradabad).
-- Not changed: Mahim (no RAC code; the Mumbai centre in the master is RETAIL ASSET WORLI 000855) and Nehru Enclave–Kalkaji (no IDBI branch of that name). Dry run 26-Nov over all 65,968 verified branch-master rows: only these 41 IDBI rows
-- change by name (SBI "Retail Asset Credit Centre", Canara "Retail Asset Hub", Axis "Retail Asset Management Group", BOB "Retail Asset Br" stay as they were;
-- the guard below stops the whole change if any non-IDBI row would change).
-- IDBI RAC units 57 → 111 (Mumbai team 2 → 10, all active; 93 of the 95 RACs on the IDBI list shown as RAC). Undo: restore bi.fn_backup (wave '122a') and drop bi.unit_type_override.

insert into bi.fn_backup(fn, def, wave)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid), '122a' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'bi' and p.proname in ('unit_type', 'api_branch_units');

-- guard: the new name rule may change IDBI rows only
do $g$ declare n_other int; n_idbi int; begin
  select count(*) filter (where client_family is distinct from 'IDBI'), count(*) filter (where client_family = 'IDBI')
    into n_other, n_idbi
    from bi.client_branch_master
   where bi.unit_type(branch_name, branch_type) not in ('RAC', 'RACPC', 'Mini RACPC', 'RACC', 'RASMECCC', 'SMECCC', 'SARC', 'Other CPC')
     and branch_name ~* '^\s*retails?\s+assets?(\s+cent(re|er))?\s+(?!(hub[a-z]*|br|branch|central|credit|small|and|sme|processing|management|group|cell|dept|division)\M)[a-z]';
  if n_other > 0 then raise exception '122a: % rows outside IDBI would change type — stop', n_other; end if;
  raise notice '122a: % IDBI rows become RAC by name', n_idbi;
end $g$;

CREATE OR REPLACE FUNCTION bi.unit_type(p_name text, p_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  select case
    when p_name ~* 'mini\s*-?\s*rac\s*pa?c' then 'Mini RACPC'
    when p_name ~* 'rac\s*pa?c' then 'RACPC'
    when p_name ~* 'rasme\s*c|rasmec' then 'RASMECCC'
    when p_name ~* 'smecc|\msme\s+ccc?\M' then 'SMECCC'
    when p_name ~* '\msarc\M' then 'SARC'
    when p_name ~* '\mrac\M' then 'RAC'
    -- 122a: IDBI "Retail Asset (Centre) <place>" is a RAC (not a hub, credit centre, processing centre or department)
    when p_name ~* '^\s*retails?\s+assets?(\s+cent(re|er))?\s+(?!(hub[a-z]*|br|branch|central|credit|small|and|sme|processing|management|group|cell|dept|division)\M)[a-z]' then 'RAC'
    when p_name ~* '\mracc\M' then 'RACC'
    when p_name ~* 'cpc' then 'Other CPC'
    when coalesce(p_type, 'branch') = 'processing_centre' then 'Other processing centre'
    when coalesce(p_type, 'branch') = 'office' and p_name ~* '\mlhos?\M|local\s+head\s+offices?' then 'LHO'
    when coalesce(p_type, 'branch') = 'office' then 'Office'
    when p_name ~* '\mm?sme\M' then 'SME branch'
    else 'Branch' end $function$;

-- units whose type cannot be read from the name (the client's own unit list says what they are)
create table if not exists bi.unit_type_override (
  client_family text not null,
  branch_code text not null,
  unit_type text not null,
  source text not null,
  note text,
  added_at timestamptz not null default now(),
  primary key (client_family, branch_code));
alter table bi.unit_type_override enable row level security;   -- read only through bi.api_branch_units
comment on table bi.unit_type_override is 'wave 122a: unit type from the client''s own unit list where the branch-master name does not say it';
insert into bi.unit_type_override(client_family, branch_code, unit_type, source, note) values
  ('IDBI', '008050', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'branch master name SALEM; RAC code series 0080xx; on the list as SALEM'),
  ('IDBI', '008027', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'branch master name SATARA; RAC code series 0080xx; on the list as SATARA'),
  ('IDBI', '008033', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'branch master name TIRUCHIRAPALLI; RAC code series 0080xx; on the list as TRICHY'),
  ('IDBI', '000437', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Bidadi works from the Bidadi branch (no separate RAC code)'),
  ('IDBI', '002310', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Frazer Town works from the Frazer Town branch (IFSC IBKL0002310; no separate RAC code)'),
  ('IDBI', '000272', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Chandigarh works from the Chandigarh branch (no separate RAC code)'),
  ('IDBI', '000550', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Karol Bagh works from the Karol Baug branch (no separate RAC code)'),
  ('IDBI', '000040', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Rajouri Garden works from the Rajouri Garden branch (no separate RAC code)'),
  ('IDBI', '000432', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Gachibowli works from the Gachibowli branch (IFSC IBKL0000432; no separate RAC code)'),
  ('IDBI', '000060', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Brabourne Road works from the Brabourne Road branch (no separate RAC code)'),
  ('IDBI', '001270', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Esplanade works from the Esplanade branch (IFSC IBKL0001270; no separate RAC code)'),
  ('IDBI', '000359', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Howrah works from the Howrah branch (no separate RAC code)'),
  ('IDBI', '000122', 'RAC', 'IDBI RAC list, Nov-2026 (shared 26-Nov)', 'RAC Moradabad works from the Moradabad branch (the list''s location column says Modinagar; to confirm)')
on conflict (client_family, branch_code) do update set unit_type = excluded.unit_type, source = excluded.source, note = excluded.note;

create or replace function pg_temp.patch(p regprocedure, olds text[], news text[]) returns void language plpgsql as $$
declare d text := pg_get_functiondef(p); i int; k int;
begin
  for i in 1 .. array_length(olds, 1) loop
    k := (length(d) - length(replace(d, olds[i], ''))) / length(olds[i]);
    if k <> 1 then raise exception 'patch %: piece % found % times', p, i, k; end if;
    d := replace(d, olds[i], news[i]);
  end loop;
  execute d;
end $$;

select pg_temp.patch('bi.api_branch_units(jsonb,jsonb)'::regprocedure,
  array['bi.unit_type(b.branch_name, b.branch_type) ut',
        'from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid'],
  array['coalesce(uo.unit_type, bi.unit_type(b.branch_name, b.branch_type)) ut',
        'from bi.client_branch_master b left join bi.v_branch_family_rule fr on fr.branch_uid = b.branch_uid
           left join bi.unit_type_override uo on uo.client_family = b.client_family and uo.branch_code = b.branch_code   -- 122a']);

insert into bi.audit_log(actor, action, entity, entity_key, detail)
values ('wave-122a', 'unit_type_rule', 'bi.unit_type', 'RAC', jsonb_build_object('change', 'IDBI Retail Asset Centre names and 13 listed codes count as RAC', 'request', 'Crux operations 26-Nov'));
delete from bi.api_cache where fn in ('branch_units', 'client_structure');

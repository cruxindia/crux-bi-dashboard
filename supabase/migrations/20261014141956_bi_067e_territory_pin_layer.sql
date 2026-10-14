-- Applied to Supabase project via MCP on 20261014141956
-- territory lookup order: exact district as published -> PIN-prefix rule ("PIN:nnn") -> state default
create or replace function bi.territory_of(p_state text, p_district text, p_pin text)
returns table(location_id int, zone_group text, basis text, confidence text) language sql stable as $$
  select t.location_id, t.zone_group, t.basis, t.confidence from bi.location_territory t
  where t.effective_to is null and t.state = upper(p_state)
    and (t.district = upper(p_district) or t.district = 'PIN:' || left(regexp_replace(coalesce(p_pin, ''), '\D', '', 'g'), 3) or t.district is null)
  order by case when t.district = upper(p_district) then 0 when t.district like 'PIN:%' then 1 else 2 end, t.id limit 1 $$;

create or replace function bi._br_parse(p jsonb)
returns table(uid text, code text, ifsc text, micr text, name text, address text, district text, state text, centre text, city text,
              pincode text, branch_type text, location_id int, zone_group text, basis text, h text, conf text)
language sql stable set search_path = bi, public as $$
  with x as (select y x, regexp_replace(coalesce(nullif(y->>'pincode', ''), substring(y->>'address' from '([1-9][0-9]{2}\s?[0-9]{3})\D*$'), ''), '\s', '', 'g') pin
             from jsonb_array_elements(coalesce(p->'rows', '[]')) y)
  select x->>'uid', x->>'code', nullif(x->>'ifsc', ''), nullif(x->>'micr', ''), x->>'name', nullif(x->>'address', ''), upper(nullif(x->>'district', '')), upper(x->>'state'),
         nullif(x->>'centre', ''), nullif(x->>'city', ''), nullif(pin, ''),
         coalesce(x->>'branch_type', 'branch'), t.location_id, t.zone_group, t.basis,
         md5(concat_ws('|', x->>'name', x->>'address', upper(x->>'district'), upper(x->>'state'), x->>'centre', x->>'branch_type', x->>'micr')),
         coalesce(x->>'confidence', 'high')
  from x left join lateral bi.territory_of(x->>'state', x->>'district', pin) t on true $$;

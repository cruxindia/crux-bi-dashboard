-- Applied to Supabase project via MCP on 20261028122455
-- bi_095a (28-Oct-2026): place reference from "Crux case mapping reference" (28-Oct-2026, authoritative business rules) and helpers that turn a
-- client branch name, a district / city / state or a payer bank branch into a Crux location. Reference rows are loaded with public.bi_ref_load
-- (admin token), not in this migration. Nothing is removed.
create table if not exists bi.ref_place (place text primary key, state text, merged_into text, grouping text, zone text, how text, location_id int references bi.location(id), loaded_at timestamptz default now());
create table if not exists bi.ref_state_default (state text primary key, grouping text, zone text, location_id int references bi.location(id), loaded_at timestamptz default now());
create table if not exists bi.ref_branch_word (word text primary key, place text not null, loaded_at timestamptz default now());
create table if not exists bi.ref_pin_prefix (prefix text primary key, place text, state text, loaded_at timestamptz default now());
alter table bi.ref_place enable row level security; alter table bi.ref_state_default enable row level security;
alter table bi.ref_branch_word enable row level security; alter table bi.ref_pin_prefix enable row level security;

-- grouping name (as in the Main Tracker) -> dashboard location
create or replace function bi.loc_of_grouping(p text) returns int language sql stable set search_path to 'bi', 'public' as $f$
  select coalesce(
    (select l.id from bi.location l where lower(regexp_replace(l.label, '\s+', ' ', 'g')) = lower(regexp_replace(btrim(p), '\s+', ' ', 'g')) limit 1),
    (select l.id from bi.location l where lower(regexp_replace(l.label, '[^A-Za-z]', '', 'g')) = lower(regexp_replace(p, '[^A-Za-z]', '', 'g')) limit 1),
    (select a.location_id from bi.location_alias a where lower(a.alias) = lower(btrim(p)) and a.location_id is not null and coalesce(a.review_status, '') <> 'rejected' limit 1)) $f$;

-- place -> location. Nagpur-area places follow the Nagpur team named in the hint (sheet / file name containing "sudhir"); Chandrapur is always Sudhir's.
create or replace function bi.loc_of_place(p_place text, p_hint text default null) returns int language sql stable set search_path to 'bi', 'public' as $f$
  with pl as (select coalesce(m.merged_into, m.place) place from bi.ref_place m where upper(m.place) = upper(btrim(p_place)) limit 1),
       g as (select r.place, r.grouping, r.location_id, r.state from pl join bi.ref_place r on upper(r.place) = upper(pl.place))
  select case when g.grouping = 'NAGPUR (YASH)' and coalesce(p_hint, '') ~* 'sudhir' then (select id from bi.location where label = 'NAGPUR (Sudhir)')
              else coalesce(g.location_id, (select s.location_id from bi.ref_state_default s where s.state = g.state)) end
  from g $f$;

-- client branch name -> place: every run of 1-4 words looked up; the match ending last wins, a longer phrase beats a shorter one at the same end.
create or replace function bi.place_of_branch(p_name text) returns text language sql stable set search_path to 'bi', 'public' as $f$
  with w as (select t.w, t.i from unnest(regexp_split_to_array(btrim(regexp_replace(upper(coalesce(p_name, '')), '[^A-Z]+', ' ', 'g')), ' ')) with ordinality t(w, i) where t.w <> ''),
       g as (select w1.i e, n, (select string_agg(w2.w, ' ' order by w2.i) from w w2 where w2.i between w1.i - n + 1 and w1.i) ph
               from w w1 cross join generate_series(1, 4) n where w1.i - n + 1 >= 1)
  select b.place from g join bi.ref_branch_word b on b.word = g.ph order by g.e desc, g.n desc limit 1 $f$;

-- payer bank branch (code or IFSC, plus the bank account's family) -> location via the client branch master, then its district / city / state.
create or replace function bi.loc_of_payer(p_family text, p_code text, p_name text) returns table(location_id int, family text, basis text) language sql stable set search_path to 'bi', 'public' as $f$
  with b as (
    select m.location_id, m.client_family, m.district, m.city, m.state, m.branch_name
      from bi.client_branch_master m
     where (p_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$' and m.ifsc = p_code)
        or (p_code ~ '^\d{1,6}$' and m.client_family = p_family and m.code_norm = ltrim(p_code, '0'))
     order by (m.location_id is null), m.client_family limit 1)
  select coalesce(b.location_id, bi.loc_of_place(b.district), bi.loc_of_place(b.city), bi.loc_of_place(bi.place_of_branch(b.branch_name)), bi.loc_of_place(bi.place_of_branch(p_name)),
                  (select s.location_id from bi.ref_state_default s where upper(s.state) = upper(b.state))),
         coalesce(b.client_family, p_family),
         case when b.location_id is not null then 'payer_branch' when b.client_family is not null then 'payer_branch_place' when bi.place_of_branch(p_name) is not null then 'payer_branch_name' end
    from (select 1) one left join b on true
   where b.client_family is not null or bi.place_of_branch(p_name) is not null $f$;

-- loader (admin token): upserts the reference sheets; returns counts and groupings without a dashboard location
create or replace function public.bi_ref_load(p_token text, p jsonb) returns jsonb language plpgsql security definer set search_path to 'bi', 'public' as $f$
declare n1 int; n2 int; n3 int; n4 int;
begin
  if not bi.token_ok(p_token) and bi.app_role() is distinct from 'admin' then raise exception 'not authorised' using errcode = '42501'; end if;
  insert into bi.ref_place(place, state, merged_into, grouping, zone, how)
  select x->>0, nullif(x->>1, ''), nullif(x->>2, ''), nullif(x->>3, ''), nullif(x->>4, ''), nullif(x->>5, '') from jsonb_array_elements(coalesce(p->'places', '[]')) x
  on conflict (place) do update set state = excluded.state, merged_into = excluded.merged_into, grouping = excluded.grouping, zone = excluded.zone, how = excluded.how, loaded_at = now();
  get diagnostics n1 = row_count;
  insert into bi.ref_state_default(state, grouping, zone) select x->>0, nullif(x->>1, ''), nullif(x->>2, '') from jsonb_array_elements(coalesce(p->'states', '[]')) x
  on conflict (state) do update set grouping = excluded.grouping, zone = excluded.zone, loaded_at = now();
  get diagnostics n2 = row_count;
  insert into bi.ref_branch_word(word, place) select upper(btrim(x->>0)), x->>1 from jsonb_array_elements(coalesce(p->'words', '[]')) x
  on conflict (word) do update set place = excluded.place, loaded_at = now();
  get diagnostics n3 = row_count;
  insert into bi.ref_pin_prefix(prefix, place, state) select x->>0, nullif(x->>1, ''), nullif(x->>2, '') from jsonb_array_elements(coalesce(p->'pins', '[]')) x
  on conflict (prefix) do update set place = excluded.place, state = excluded.state, loaded_at = now();
  get diagnostics n4 = row_count;
  update bi.ref_place set location_id = bi.loc_of_grouping(grouping) where grouping is not null;
  update bi.ref_state_default set location_id = bi.loc_of_grouping(grouping) where grouping is not null;
  insert into bi.audit_log(actor, action, entity, entity_key, detail) values ('ref-loader', 'cache_bump', 'ref_place', 'case mapping reference',
    jsonb_build_object('places', n1, 'states', n2, 'words', n3, 'pins', n4));
  return jsonb_build_object('places', n1, 'states', n2, 'words', n3, 'pins', n4,
    'groupings_without_location', (select coalesce(jsonb_agg(distinct grouping), '[]') from (select grouping from bi.ref_place where grouping is not null and location_id is null
                                    union select grouping from bi.ref_state_default where grouping is not null and location_id is null) z));
end $f$;
grant execute on function public.bi_ref_load(text, jsonb) to anon, authenticated;

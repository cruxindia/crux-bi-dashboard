-- Applied to Supabase project via MCP on 20261113174510
-- wave 110b: question trends group wordings of the same question by meaning (saved question embeddings, similarity ≥ 0.90), and by type + key words when a question has no embedding
create or replace function bi.api_ask_trends(p jsonb) returns jsonb language sql stable security definer set search_path to 'bi', 'public', 'extensions' as $f$
  with prm as (select least(greatest(coalesce((p->>'days')::int, 14), 1), 90) d, coalesce((p->>'admin')::boolean, false) adm, nullif(p->>'section', '') sec),
  m as (select m.id, m.question, m.created_at, m.helpful, m.mode, m.q_embedding, coalesce(o.section, '') section, coalesce(o.admin, true) adm, o.kind okind, o.title
          from bi.ai_message m left join lateral (select a.section, a.admin, a.kind, a.title from bi.ask_origin a where a.message_id = m.id order by a.id desc limit 1) o on true
         where m.created_at > now() - make_interval(days => (select d from prm)) and length(m.question) between 6 and 300),
  v as (select * from m where ((select adm from prm) or not m.adm)
          and not exists (select 1 from bi.employee e where length(e.name_key) >= 8 and upper(m.question) like '%' || e.name_key || '%')),
  t as (select v.*, case
     when question ~* '\m(how many|count|counts|number of|no\.? of)\M' then 'count'
     when question ~* '\m(why|reason|root cause|explain)\M' then 'why'
     when question ~* '\m(compare|comparison|versus|vs)\M' then 'compare'
     when question ~* '\m(list|which|names?|details?)\M' then 'list'
     when question ~* '\m(trend|growth|grew|mom|yoy|qoq|over time|spike|dips?)\M' then 'trend'
     when question ~* '\m(target|shortfall|achiev\w*|pace|likely)\M' then 'target'
     when question ~* '\m(tat|turnaround|sla|backlog|pending|force1)\M' then 'operations'
     when question ~* '\m(collections?|outstanding|receivables?|ageing|realisation)\M' then 'collections'
     when question ~* '\m(potential|bau|opportunit\w*|organic)\M' then 'potential'
     when question ~* '\m(revenue|business|amount|value)\M' then 'value'
     else 'other' end qtype,
     (select string_agg(w, ' ' order by w) from (select distinct case when length(w) > 4 and w ~ 's$' then left(w, -1) else w end w
        from regexp_split_to_table(lower(regexp_replace(question, '[^A-Za-z ]', ' ', 'g')), '\s+') w
        where length(w) > 2 and w not in ('the','and','for','give','gave','me','what','show','please','all','this','that','with','how','many','much','can','you','are','was','were','from',
          'data','its','our','have','has','get','tell','about','does','did','there','their','them','which','who','when','where','why','also','same','into','per','any','some','let','see',
          'want','need','only','not','but','now','then','than','more','most','each','every','list','details','detail','count','number','total')) z) sig
     from v),
  -- the earliest question in the window that means the same (cosine similarity ≥ 0.90) is the cluster's root
  k as (select t.*, case when t.q_embedding is not null
                          then 'e' || (select min(t2.id) from t t2 where t2.q_embedding is not null and (t2.q_embedding <=> t.q_embedding) <= 0.10)
                          else 's' || t.qtype || ':' || coalesce(t.sig, '') end ckey from t),
  cl as (select ckey, mode() within group (order by qtype) qtype, count(*) n, count(distinct lower(trim(question))) variations, max(created_at) last_at,
                (array_agg(question order by created_at desc))[1] question, count(*) filter (where helpful) helpful_yes, count(*) filter (where helpful is false) helpful_no,
                mode() within group (order by nullif(section, '')) section
           from k where (select sec from prm) is null or section = (select sec from prm) group by 1)
  select jsonb_build_object('days', (select d from prm), 'questions', (select count(*) from t),
    'clusters', (select coalesce(jsonb_agg(jsonb_build_object('question', question, 'type', qtype, 'asked', n, 'variations', variations, 'helpful_yes', helpful_yes, 'helpful_no', helpful_no,
                   'section', section, 'last', to_char(last_at at time zone 'Asia/Kolkata', 'DD-Mon HH24:MI')) order by n desc, last_at desc), '[]')
                 from (select * from cl order by n desc, last_at desc limit 25) z),
    'by_type', (select coalesce(jsonb_object_agg(qtype, n), '{}') from (select qtype, count(*) n from t group by 1) q),
    'by_section', (select coalesce(jsonb_object_agg(s, n), '{}') from (select nullif(section, '') s, count(*) n from t where nullif(section, '') is not null group by 1) q),
    'elements', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'kind', okind, 'section', section, 'asked', n) order by n desc), '[]')
                 from (select title, okind, section, count(*) n from t where title is not null and okind in ('tile', 'table', 'chart', 'card') group by 1, 2, 3 order by 4 desc limit 12) q),
    'feedback', (select jsonb_build_object('helpful', count(*) filter (where helpful), 'not_helpful', count(*) filter (where helpful is false)) from t))
$f$;
delete from bi.api_cache where fn = 'ask_trends';

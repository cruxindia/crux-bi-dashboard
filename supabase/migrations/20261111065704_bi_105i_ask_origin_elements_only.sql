-- Applied to Supabase project via MCP on 20261111065704
-- wave 105i: "elements" and "from_elements" count only questions asked from an element (tile, table, chart, briefing card, details panel);
-- suggested questions, follow-ups, the menu and the panel itself stay in the page totals and in "kinds" (found in the 11-Nov chat review test).
create or replace function bi.ask_origin_counts(p_since timestamptz, p_until timestamptz default now(), p_limit int default 20) returns jsonb language sql stable security definer set search_path = bi, public as $f$
  with o as (select o.*, m.helpful from bi.ask_origin o left join bi.ai_message m on m.id = o.message_id where o.at >= p_since and o.at < p_until)
  select jsonb_build_object(
    'total', (select count(*) from o),
    'pages', coalesce((select jsonb_agg(x order by (x->>'n')::int desc, x->>'section') from (
        select jsonb_build_object('section', section, 'page', max(page), 'n', count(*), 'from_elements', count(*) filter (where kind in ('tile', 'table', 'chart', 'card', 'drill')),
                                  'ai', count(*) filter (where path = 'ai'), 'memory', count(*) filter (where path = 'memory'), 'calculated', count(*) filter (where path = 'calculated'),
                                  'errors', count(*) filter (where path = 'error'), 'helpful', count(*) filter (where helpful), 'not_helpful', count(*) filter (where helpful is false),
                                  'last', max(at)) x
          from o group by section order by count(*) desc limit p_limit) z), '[]'::jsonb),
    'elements', coalesce((select jsonb_agg(x order by (x->>'n')::int desc, x->>'title') from (
        select jsonb_build_object('section', section, 'page', max(page), 'kind', kind, 'title', title, 'n', count(*),
                                  'helpful', count(*) filter (where helpful), 'not_helpful', count(*) filter (where helpful is false), 'last', max(at)) x
          from o where kind in ('tile', 'table', 'chart', 'card', 'drill') group by section, kind, title order by count(*) desc limit p_limit) z), '[]'::jsonb),
    'kinds', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from o group by kind) k), '{}'::jsonb))
$f$;
revoke all on function bi.ask_origin_counts(timestamptz, timestamptz, int) from public, anon, authenticated;

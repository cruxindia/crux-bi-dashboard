-- Applied to Supabase project via MCP on 20261107154247
-- Wave 101b: "will we hit the target this month" stays a month-end question; only "targets ... months" (plural) means the plan.
do $m$
declare d text := pg_get_functiondef('public.bi_ask3(text, jsonb, uuid)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, $a$targets?.{0,40}\mmonths?\M|\mmonths?.{0,25}targets?|$a$, $a$targets?.{0,40}\mmonths\M|\mmonths.{0,25}targets?|$a$);
  if d = o then raise exception 'routing edit'; end if;
  execute d;
  d := pg_get_functiondef('bi.ask_h_plan(date, jsonb, text)'::regprocedure); o := d;
  d := replace(d, $a$|targets?.{0,40}\mmonths?\M)';$a$, $a$|targets?.{0,40}\mmonths\M)';$a$);
  if d = o then raise exception 'plan edit'; end if;
  execute d;
end $m$;

-- Applied to Supabase project via MCP on 20261028145153
-- bi_096h (28-Oct-2026): method texts follow the case-location rules (bi_096a/e); the outstanding gap explanation lists only rows that differ.
do $do$
declare d text; o text; n text;
begin
  d := pg_get_functiondef('bi.api_force1(date,jsonb)'::regprocedure);
  o := $o$A Force1 case belongs to the tracker location of its bank branch (client branch master); when the branch is not located, to the team that processed it.$o$;
  n := $n$A Force1 case belongs to the tracker location of its bank branch (client branch master); when the branch is not in the master, to the location found by the case-location rules (area office, place in the branch name, the branch customers'' area, residence pincode, then the file''s usual location).$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'api_force1 fragment'; end if;
  execute replace(d, o, n);
  d := pg_get_functiondef('bi.ask_h_force1_recon(date,jsonb)'::regprocedure);
  o := $o$a Force1 case counts at the location of its bank branch, and per$o$;
  n := $n$a Force1 case counts at the location of its bank branch (else where the case-location rules place it), and per$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'ask_h_force1_recon fragment'; end if;
  execute replace(d, o, n);
  d := pg_get_functiondef('public.bi_ask3(text,jsonb,uuid)'::regprocedure);
  o := $o$from jsonb_array_elements(rc->'rows') x where x->>'status' <> 'matches' or abs((x->>'diff_total')::numeric) >= 1)) end;$o$;
  n := $n$from jsonb_array_elements(rc->'rows') x where abs(coalesce((x->>'diff_total')::numeric, 0)) >= 1)) end;$n$;
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'bi_ask3 fragment'; end if;
  execute replace(d, o, n);
end $do$;

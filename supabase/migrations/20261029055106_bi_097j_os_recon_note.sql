-- Applied to Supabase project via MCP on 20261029055106
-- bi_097j (29-Oct-2026): accuracy of the cross-sheet invoice note. Outstanding lines are stored without the branch (and never with the applicant),
-- so "same lines" compares client, invoice month, basic and outstanding only — an upper bound, not proof of a double count. The note said "branch" was compared.
do $do$
declare d text := pg_get_functiondef('bi.api_os_recon()'::regprocedure);
        o text := $o$'Lines are compared on client, branch, invoice month, basic and outstanding; applicant names are never stored, so two lines that differ only in the applicant count as the same here.'$o$;
        n text := $n$'Lines are compared on client, invoice month, basic and outstanding. The branch and the applicant are not stored for outstanding lines, so two lines that differ only in branch or applicant count as the same here: "same lines" is an upper bound for lines counted twice, to be confirmed in the workbook before any correction.'$n$;
begin
  if (length(d) - length(replace(d, o, ''))) / length(o) <> 1 then raise exception 'api_os_recon note not found exactly once'; end if;
  execute replace(d, o, n);
end $do$;

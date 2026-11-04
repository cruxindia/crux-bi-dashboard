-- Applied to Supabase project via MCP on 20261104141415
-- 4-Nov-2026: identity check I08 found 6 cases whose stored location no longer matched the rules — later cases of the same branch
-- changed that branch's evidence, and a commit only re-checks the cases in its own file. They were corrected with
-- bi.case_relocate_apply (audited). From now on every case is re-checked weekly at night, just before the weekly identity audit.
select cron.schedule('bi-case-relocate-weekly', '30 20 * * 6',
  $c$set statement_timeout = '600s'; select bi.case_relocate_apply('weekly re-check of every case against the location rules', null);$c$);

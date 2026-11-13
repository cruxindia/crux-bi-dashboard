# Test note — weekly improver — LHO as a unit type (14-Nov-2026)
| Test | What | Result |
|---|---|---|
| IMP-LHO-1 | `unitQuestion()` on this week's unit questions (bundled agent.ts run in Node) | LHO and "local head office" questions now recognised as unit questions (type LHO, client kept); RACPC / Mini RACPC / RASMECCC / RAC / branch questions unchanged; non-unit questions still null ✓ |
| IMP-LHO-2 | Every ask-crux file transpiled (esbuild) and syntax-checked (`node --check`) | 5 / 5 ok ✓ |
| IMP-LHO-3 | Proposal SQL (`supabase/proposals/2026-11-14_lho_unit_type.sql`) parsed (SQL and PL/pgSQL parser) and compared with the live definitions: live text + the three intended edits has the same checksum as the proposal | identical ✓ (not applied) |
| IMP-LHO-4 | Read-only dry run of the new type rule on the branch master | only rows typed Office change, all to LHO; no other row changes type ✓ |
| IMP-LHO-5 | Before the SQL is applied: the fast unit answer steps aside for LHO (the agent answers) and the tool result tells the agent not to report zero LHO units | by code review ✓ |

(Kept in its own file so improver pull requests do not conflict with each other in docs/TEST_REPORT.md.)

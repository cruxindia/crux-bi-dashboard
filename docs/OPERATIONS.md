# Operations guide

## Daily / monthly refresh (admin)
1. Open the dashboard → **Upload centre**.
2. Drop any mix of tracker snapshots and Case/Point Wise files. Each is identified, previewed (row counts, tracker control total) and validated in the browser; PII is removed before upload.
3. Correct the detected location group / month / snapshot date if needed, then **Import validated files**.
4. Re-uploading an identical file does nothing. A corrected file updates only changed records; history and the import audit are kept (`bi.import_batch`, `bi.audit_log`).
5. A new month starts automatically with the first snapshot of that month.
6. After large uploads, re-run classification (People → *Re-run classification*) and tests: `select * from bi.run_acceptance_tests();`.

## Mappings and exceptions
Data quality → exceptions (status open/accepted/resolved), location aliases (confirm / reject / needs review), point-type categories. All edits are audited.

## Access
* Viewing: open the GitHub Pages link — no login.
* Admin: Upload centre / Data quality → enter the admin key (kept for the browser session only).
* New admin key: generate a random string, insert its SHA-256 hash into `bi.ingest_token` with an expiry; revoke with `update bi.ingest_token set revoked=true where label=…`.
* Bulk-load token: create random token, store `encode(digest(token,'sha256'),'hex')` in `bi.ingest_token` with an expiry; revoke after use.

## Hosting options for the standalone app (`web/index.html`)
1. Keep using the Claude artifact (live via each admin's Supabase connector) — works today.
2. GitHub Pages: requires a paid GitHub plan for a private repo, or making the repo public (code only — still safe because data access needs Supabase Auth + approved role).
3. Any static host (Netlify, Cloudflare Pages, Supabase-adjacent hosting).

## Troubleshooting
* "not authorised": the signed-in email is not in `bi.app_user` or not confirmed.
* Upload "Already imported": same file hash already committed.
* Tracker control mismatch warning: the file's own Pan India row disagrees with its leaf rows; leaf rows are used and the mismatch is logged.

## Daily update table (Upload centre) — replaces the routine tracker upload
1. Unlock with the admin key → Upload centre → "Zonal Tracker — daily update table". Pick the month; enter your name (audit trail).
2. Choose **Daily counts** (each date's count, like the Test Details sheet) or **Cumulative MTD**. Committed dates are grey; open dates (missing / draft / correcting) are editable.
3. Type, or paste from Excel: a plain column fills downward; rows copied together with their Location and Client columns are matched by name (total rows are skipped). "Fill blanks with 0" sets untouched cells to no business for that date.
4. Save all changes → pick the date → Validate (optional control total = Pan India MTD from the source) → tick "Accept warnings" + reason if needed → Commit this date, or "Commit all open dates in order".
5. Holidays: "Mark no report". Wrong figures already committed: ✎ on the date header → reason → edit → validate → commit (old values archived).
6. New month: tick "Edit target & rate" and enter the month's targets (and changed rates) before the first commit.

## WEF group changes (Data quality)
Pick location → group type → new value → WEF date → reason + your name → Preview impact → Save. Future-dated changes are applied to today's mapping by the daily job `bi-wef-sync`.

## Migrations
All migrations through `bi_082b` are applied (exported automatically to `supabase/migrations/`). When writing new ones, avoid top-level DROP/REVOKE/UPDATE/DELETE — the Supabase connector cancels them; use `create or replace` and guarded `do` blocks. After applying, run `select * from bi.run_acceptance_tests();` (27 tests) `select * from bi.run_addendum_tests();` (8 tests) and `select * from bi.run_wave_tests();` (4 tests) — run each on its own (together they exceed the statement time limit). New functions in schema `bi` are not reachable by the public key (no schema access); expose them only through `bi_call` (read) or `bi_admin` (write, key required).

## Business tracker (Zonal Tracker view)
Pick the month at the top, then the snapshot. Levels: Summary / Zones / Locations / All rows (like Excel outline). ▸/▾ collapses a zone or a location block. Click a column header to sort within blocks. "Compare" adds MTD-then, Δ and Δ% columns. "History" adds Actual MTD / Revenue / Billing per past month. "Export to Excel" downloads exactly the rows and columns on screen.

## Master data — client branch lists and the workforce list (Data quality)
1. Unlock with the admin key → Data quality → "Master data". Choose **Client branch master** or **Workforce master** → **Download template** (includes "Read me", valid clients and valid locations).
2. Fill one sheet. Required: branch list — client, branch_code, source, verified_on; workforce — name, role, joining_date, source. Common HR headings (Emp Code, Employee Name, Designation, DOJ, LWD) are recognised. Keep branch codes as Text to preserve leading zeros.
3. Choose the file → **Check file**. Nothing is saved; the result lists every problem with its sheet row (unknown client/location, missing or bad dates, exit before joining, repeated keys).
4. Enter your name → **Import valid rows**. Rows with problems are skipped. Re-uploading updates rows with the same key; uploads never remove rows — mark branches `closed`/`ineligible` or give people an exit date instead. Branch rows that match an official-source branch (same client family, same code ignoring leading zeros) leave the official record unchanged; a different status is sent to the branch review queue.
5. Results: Business tracker → "Branch coverage vs verified client branch list"; People → "Headcount & attrition". Leaver names are visible to admins only.

## Rate change during the month (Upload centre → daily update table)
Open "Rate changes from a date" → choose location (or all) and client (or all) → new rate, effective date, reason → **Preview impact** (nothing saved) → **Apply**. Cases reported before the date keep the old rate. "Undo" (with a reason) restores the previous rate. A rate typed in the table with "Edit target & rate" becomes a change from that report date.

## Penalties (Upload centre → Penalties; Business tracker shows them read-only)
Admins (admin key, checked on the server): date, location, client (optional), amount, reason (required), reference → Add. "Cancel" needs a reason; cancelled penalties stay in the audit trail. Viewers see amounts; reasons are admin-only.

## Organic benchmark
Recomputed by the `bi-organic-refresh` job (every 10 minutes, only when data changed; < 1 s). Manual: `select bi.organic_refresh();`.
Method from 22-Oct-2026: 50 % last month (MoM), 40 % last quarter with its trend (QoQ), 10 % the location × client's own pattern for the same month last year (YoY); see METRICS. Check: `select bi.test_organic();` (≈ 10 s).

## Branch managers (Admin → Master data & mapping)
- **Hand-over:** choose the location (and the client only when one client has its own manager there), type the new manager, set *from* = first day, keep *end the current one the day before* ticked → Add assignment. The previous row gets its last day automatically and the audit row records it.
- **Correct a wrong row:** *End / withdraw…* → *Withdraw (entered by mistake)* with a reason. The row is kept for audit and no longer used. Then add the correct row.
- **Stop an assignment:** *End / withdraw…* → last day → *End assignment*.
- Rankings, drills, the organic breakdown *By branch manager* and Ask Crux use the change from the next load (the response cache follows the audit log).
- Names are entered here (or loaded by the owner with SQL); never put them in migrations or the repository.

## Lumen bill extractor (shares this project)
- **What:** the bill-extraction app at cruxindia.github.io/lumen_billextractor uses the `public` schema (12 tables: invoices, applicant_lines, checks, field_confidence, ingest_log, failed_uploads, payments, branches, clients, district_codes, crux_identity, review_progress), its functions (sync_invoice, lookup_branch, …) and the storage buckets `ocr` (OCR engine, public) and `bills` (bill files, private). **Do not delete any of these; never run `remove_old_invoice_app.sql` again** (SOW D84).
- **Rebuild files** (kept outside this repo, in the Lumen folder on Drive next to `reset_data.sql`): `lumen_restore_v1.sql` (tables, access, functions) and `lumen_owner_step.sql` (functions that remove rows — owner runs it in the SQL Editor; done 15-Oct). Master data (branches, district codes, CRUX identity) reloads from the 12-Aug `*_rows.csv` exports in the same folder.
- **Health check:** in the app, the database pill is green, "realtime connected" appears in the diagnostic log, and Branch master shows 570+ branches.

## Client branch master and monthly monitor
- **Where to look:** Data quality → "Client branch research & monthly monitor" (completeness, by client, by location, monitor runs) and, with the admin key, "Branch review queue". Business tracker → "Branch coverage vs verified client branch list".
- **Schedule:** cron `bi-branch-monitor` runs on the 2nd of each month, every 10 minutes from 01:00 to 03:50 UTC, until the run completes. Each call is one resumable step of at most ~110 s. If the RBI IFSC release has not changed it records a quiet skip.
- **What it does:** reads the latest RBI IFSC release, compares every bank client in scope with the master, adds new high-confidence branches, records material changes in history, marks branches not seen as "status uncertain" with a review item (never closed automatically), checks the lenders' locator pages for changes (a change opens a review), refreshes coverage.
- **Failures:** a failed or partial run appears in red in Data quality with its error; "last successful run" is not updated; the next cron call retries. An overdue banner appears if no run has succeeded for 35 days.
- **Manual run:** `select bi.call_edge('branch-monitor', '{"force":true}'::jsonb);` (admin SQL) — the job token is read from Vault; never paste it anywhere.
- **Review queue:** Resolve / Dismiss with a note; "Confirm closed" (only for "no longer listed") closes the branch with history.
- **Job token:** stored only in Vault (`bi_job_token`), scope `job`, cannot unlock admin actions. To rotate (SQL editor, owner):
  ```sql
  do $$ declare t text := encode(extensions.gen_random_bytes(32), 'hex'); begin
    update bi.ingest_token set revoked = true where scope = 'job' and not revoked;
    insert into bi.ingest_token(token_hash, label, expires_at, revoked, scope)
    values (encode(extensions.digest(t, 'sha256'), 'hex'), 'Scheduled jobs (rotated)', now() + interval '5 years', false, 'job');
    perform vault.update_secret((select id from vault.secrets where name = 'bi_job_token'), t);
  end $$;
  ```

## Ask Crux and Gemini
- **Secret:** `GEMINI_API_KEY` is set only in Supabase → Edge Functions → Secrets. To rotate: create a new key in Google AI Studio → replace the secret → run "validate" (below) → delete the old key in AI Studio.
- **Settings (non-secret, table `bi.ai_config`):** `GEMINI_MODEL` (gemini-2.5-flash), `GEMINI_FALLBACK_MODEL` (gemini-3.5-flash-lite), `GEMINI_EMBEDDING_MODEL` (gemini-embedding-2), `EMBED_DIM` 768, `AI_ENABLED` on/off, `AI_DAILY_CAP` 200, `EMBED_DAILY_CAP` 600, `AI_TIMEOUT_MS`, `AI_MAX_RETRIES`. Turn AI wording off instantly: `AI_ENABLED` = off (answers stay complete).
- **Validation:** cron `bi-ai-validate` (2nd of each month) lists the models, runs a synthetic call and records the result in `bi.ai_model_check`; Data quality → "Ask Crux — AI status" shows the model, last check, calls and failures today.
- **Knowledge base:** 77 approved definitions/methods; cron `bi-ai-embed-sync` embeds new or changed chunks daily. Add or edit documents with `bi_admin('kb', …)` (admin key).
- **Privacy:** questions and answers are redacted (e-mails, phone numbers, IDs, long numbers) before they reach Google; answers naming a person never use AI wording; figures are masked.

## Filters and drill-down (15-Oct-2026)
- **Filters:** the "Filters" button in the header (shows the month and, on wide screens, the selection; the badge counts optional filters). Opens a popover (desktop) or bottom sheet (phone). Reset clears everything except the month; Done, Escape or a click outside closes it. The choice is kept while moving between sections and for the browser session.
- **Drill-down:** click any KPI tile, chart bar/point, highlighted zone, opportunity or table row with a › marker. The drawer keeps the current filters, shows the selected value and its parent total, and a breakdown whose rows open the next level (zone → location → client → branch → branch detail). Back goes one level up, Reset to the first level, Close or Escape exits; "Ask Crux" asks about the open item. Sorting, searching, expanding tracker blocks and buttons inside tables do not open the drawer.
- **Where figures come from:** business figures = Zonal Tracker (same as Overview and tracker); branch rows = Force1 cases; the drawer says which.

## Mapping corrections (Data quality & mapping → Location aliases / Client aliases → Correct target)
1. Unlock with the admin key. In the Location aliases or Client aliases table click **Correct target** on the row.
2. Choose the new location/client and the effective date (01-Apr-2024 … today) → **Preview**: current and proposed target, tracker rows/snapshots and Force1 cases that would move. Nothing is saved.
3. Enter a reason (5+ characters) → **Apply**. Records from the effective date move; earlier records stay; the alias now points to the new target for future uploads; the cache is refreshed and the visit table rebuild is queued.
4. "History" lists every correction (who, when, from → to, effective date, reason, affected counts). To undo, apply a correction back to the old target.
- File-group (Case Wise) location mappings are changed with the WEF group editor instead.

## Storage housekeeping
- `bi.branch_seen` has fillfactor 50 so monthly monitor updates do not grow its index. After large one-off loads, `vacuum (full, analyze)` on the loaded table reclaims space (takes a short lock; no data removed).
- Check size: `select pg_database_size(current_database()), (select sum(pg_database_size(datname)) from pg_database);` — the free plan turns read-only at 500 MB.

## Drill-down detail, TAT expand and compare (15-Oct-2026)
- **Drawer sections:** business tiles (incl. Status RAG, vs same point last month, revenue, penalties), breakdown (tick rows to compare; Columns adds TAT / Force1 / branch / revenue / penalty columns), 12-month history, Turnaround time, Force1 utilisation, Branches (status and coverage, top-10 actions), What needs attention, Daily additions. KPI tiles on the Overview (incl. Revenue, Force1, Case TAT, SLA) open the drawer at the matching section.
- **TAT expand:** "▸ Show document & field TAT" anywhere TAT appears; the choice applies everywhere and is remembered in this browser.
- **Compare:** tick rows, use "＋ Add to compare" on any drawer item or branch, then "Compare n" in the tray at the bottom of the drawer (up to 6). "Compare with previous month / last year" opens a two-column comparison directly. Export CSV from the grid.
- **Warm-up job:** cron `bi-warm-drill-cache` (every 10 min) pre-computes Pan India and zone panels for the latest month after a data change; status in `bi.cache_warm`. Manual: `select bi.warm_drill_cache(240);`.
- **Tests:** `select * from bi.run_drill_ops_tests();` (6 tests) — run on its own.

## Finance workbooks (Admin → Upload; Data health → Finance review)
1. Drop the collection and/or outstanding workbook into the upload area. The browser reads it, removes personal fields, and shows a summary: sheets, rows, totals, receipt period or snapshot date, and the file's own checks (e.g. a summary sheet that does not add up).
2. For the outstanding workbook, check the snapshot date (pre-filled from the file date and the "till Mon-YY" label) and correct it if needed.
3. Press Import. Rows are staged in chunks, the row count per sheet is checked against the file, and the figures are rebuilt (or within 10 minutes by job `bi-fin-derive`). Re-importing the same file changes nothing; a re-saved copy with exactly the same rows (new file, same content) is recognised by its content hash and not imported (chip "same rows as …").
4. A later collection workbook for the same financial year replaces the earlier one (it is cumulative); outstanding workbooks are kept by snapshot date and never added.
5. Data health → Finance review queue: set each item to accepted / resolved / ignored with a note; correct a location mapping (invoice series, location name or sheet) — figures are rebuilt immediately.
6. Admin records: Revenue & collections → "Invoice and receipt records" (or click a location row) lists the invoices or receipts behind a figure.

## Admin workspace (22-Oct-2026)
- **Sign in:** top bar → **Admin login** → admin key → Unlock. The button becomes **Admin workspace** (green dot) and opens a menu of eight groups. The key is checked by the server on every admin call and is kept only in this browser tab (sessionStorage).
- **Groups:** File uploads & daily tracker corrections · Master data & mapping (aliases with effective dates, WEF groups, point types, client branch list) · Data-quality exceptions & reconciliation (import checks, exceptions with evidence, data coverage, Force1 vs business count) · Branch research & monitor · HR / workforce master data (workforce list, employee classification) · Finance review & records · Penalties (entry, cancellation, audit history) · Database health & maintenance (size vs limit, largest tables, jobs, storage, AI status).
- **Session end:** **Lock admin** in the menu; automatic lock when the key expires (expiry from the server), when the server answers "admin key required", and on the 5-minute re-check. Admin pages then return to Executive overview and admin controls disappear.
- **Old links:** #upload → Admin › uploads; #quality and #force → Admin pages for admins, Data readiness for everyone else.
- **Business pages are read-only for everyone** (People classification overrides moved to HR / workforce master data; penalty entry and cancellation only in Admin › Penalties; invoice records only in Admin › Finance).

## Storage (22-Oct-2026)
- Live figures: Admin workspace → Database health. The 500 MB Free-plan limit applies to the sum of all databases.
- Re-imports no longer rewrite unchanged rows (trigger `zz_skip_noop_update`). To roll back: `alter table bi.point_store disable trigger zz_skip_noop_update; alter table bi.case_store disable trigger zz_skip_noop_update;`
- Owner step: `supabase/owner/owner_storage_cleanup.sql` — index drop about 17.7 MB (23 MB after the next full rebuild of point_derived), stale response-cache rows about 5.9 MB, cron history under 1 MB. Upgrade or archive decision: SOW Q10/Q19.
- Safe compaction used on 22-Oct (no data change): `vacuum (full, analyze) bi.organic_store, bi.zt_row, bi.employee, bi.branch_activity, bi.api_cache, bi.fin_review;` and `reindex index bi.point_derived_pkey;` — each needs a moment of exclusive lock and free space equal to the new table. `branch_seen` keeps fill factor 50 on purpose.
- **After any VACUUM FULL, run a plain `vacuum (analyze)` on the same tables.** VACUUM FULL leaves the visibility map empty; until a plain vacuum rebuilds it, index-only scans and `pgstattuple_approx` read whole tables (22-Oct: Database health took 15 s and the admin page failed to load; 0.9 s after `vacuum (analyze)`).
- If space is needed again after many re-imports: `vacuum (full, analyze) bi.point_store, bi.case_store;` at a quiet time (locks the tables for about a minute; no data change).

## Revenue-first analysis (22-Oct-2026)
- **Measure switch** (Growth & trends, Organic vs actual, Executive overview period comparison): *Actual billed revenue* (default) or *Cases*. The choice is kept for the browser tab and applies to scorecards, rankings, organic tables, trend chart, drills and exports together.
- **Which months are compared:** only completely billed months (snapshot date ≥ month end + 30 days). After a new outstanding workbook is imported the comparable month moves forward automatically; change `billing_complete_days` in `bi.fin_config` only if invoicing practice changes.
- **Unavailable periods** (QoQ, YoY, quarter vs last year, YTD on invoices) show the reason and the expected-minimum benchmark until enough complete months exist (YoY needs Mar-2027).
- **Revenue & collections** has two views: *Business performance* (billed vs expected, per case, movers, billing gap) and *Cash & receivables* (cash by receipt month, invoice cohorts with realisation, cash allocated, TDS, outstanding and ageing, cut-off dates).
- **Checks:** `select * from bi.test_growth_rev();` (live recalculation) and `select * from bi.test_fin_fixtures();` (controlled fixtures, rolled back — safe on production; it briefly holds row locks on the finance tables, so run it outside an import).
- **Invalidating the response cache after an API change:** insert an `audit_log` row with action **`cache_bump`** (excluded from `bi.point_source_version`). Any other action also marks the derived tables stale: on 22-Oct an `api_change` row made the jobs rebuild `point_derived` (≈ 100 s, TRUNCATE + INSERT; Force1 pages and Database health wait on its lock meanwhile), `tat_month_stat` (42 s) and `organic_store`, and the warm-up job ran its full 240 s budget.
- Tables that the scheduled jobs rebuild (`point_derived` and its key, `organic_store`, `employee`, `branch_activity`) grow back after VACUUM FULL / REINDEX at their next rebuild; compaction is durable only for tables written by imports (`zt_row`, `fin_review`, `case_store`, `point_store`).

## Branch managers (28-Oct-2026, wave 094)
- **Assign a manager to one client only** (Admin workspace → Master data & mapping → Branch managers): choose the location, then in *Client (optional)* pick "‹client› only" (client code) or the client family; enter the *from* date; leave *end the current one the day before* ticked (default) when it replaces someone. Precedence: client > family > location.
- **Correct a spelling:** pick the name in *Correct spelling*, type the correct name, press *Correct spelling* — every row with that name changes; the change is audited (`branch_manager_rename`).
- **Where managers appear:** Overview → branch-manager panel (expected revenue so far, on course for, billed / collected / outstanding allocated; click a row for the drawer), People → Branch managers and hand-overs, business tracker column *Branch manager*, rankings and drills (before Stakeholder), Ask Crux ("How is ‹name› doing?", "Which branch managers are behind?", "What changed after the hand-overs?").
- **Measures:** Growth, Organic and the Overview comparison open on *Expected revenue* (business); *Billed revenue* (finance) and *Cases* are one click away and remembered for the session.
- **Finance dates:** billed months move forward when a newer outstanding workbook is imported; October collections move forward only when a newer collection workbook is uploaded (the latest ends 13-Oct-2026).
- **Checks:** `select * from bi.test_bm();` (11 live checks, read-only).

## Finance identity (28-Oct-2026, wave 095)
- **Collection workbook:** upload as before (Admin workspace → File uploads). The extractor now also keeps each line's paying bank branch code / IFSC, branch name and any invoice number quoted in the narration (the narration itself is never stored). A re-saved copy with the same rows is still refused; the new columns make a first re-import of an old file a new upload that replaces the earlier one (no double counting).
- **Improve identification:** write the location or branch in the workbook row; add an invoice-series or label line in Admin workspace → Finance review & records (finance review queue → location mapping form). Zone-level series (GUJ, CHH, UP / LUK, AHN) stay "not attributable" unless a row names a place.
- **Reference rules:** to reload the case-mapping reference after it changes, call `public.bi_ref_load` with the admin token (upsert; nothing is removed).
- **Checks:** `select * from bi.test_fin_attr();` and `select * from bi.test_bm();`.

## Case location, operations, outstanding and roles (28-Oct-2026, wave 096)
- **Case location:** applied automatically to every Case Wise upload batch (`bi.case_relocate_apply` from `relocate_cases`). To re-run for all cases after the reference changes, schedule a one-off cron job with `set statement_timeout = '10min'` and `select bi.case_relocate_apply('manual <date>');` (≈ 3–5 min); every move is logged in `bi.case_loc_change` and audited as `case_relocation`. Dry run: `select basis, count(*) from bi.case_locate() group by 1;`
- **Operations / ageing:** `select public.bi_call('ops', '{"month":"2026-10-01","filters":{}}');` — check `closing_backlog = open_now_check` and Σ ageing = closing.
- **Outstanding reconciliation:** `select public.bi_call('os_recon', '{}');` — `reconciled`, the row-by-row table and the listed adjustments.
- **Roles:** Admin workspace → Mapping → "Operations handlers and collections owners" (add with a start date, tick "end the current one", withdraw with a reason). Every change is in `bi.audit_log` (`branch_role_*`).
- **Branch coverage:** the monthly monitor (cron `bi-branch-monitor`, 2nd of the month) compares with the latest RBI IFSC release; a manual run is `select bi.call_edge('branch-monitor', '{"trigger":"manual"}');` — "skipped" means the source has not changed.

## Identity register, reconciliation and roles (29-Oct-2026, wave 097)
- **Identity register:** weekly (cron `bi-identity-weekly`, Sunday 02:20 IST) or Admin → Data quality → "Rebuild the register now". Check: `select * from bi.test_identity();` (15 rows, all true).
- **Point policy after a Point Wise upload:** applied by `refresh_if_stale` before the derived table is rebuilt. Dry-run: `select bi.point_locate_apply('check', false);`.
- **Tracker labels with a new team suffix** are mapped to the existing location and listed under Admin → Mapping for review; change the target with "retarget" if the team really is a new location.
- **Finance workbooks:** Admin → File uploads shows the detected dates and per-sheet checks before import; after import the live status appears; Revenue & collections → Cash shows the outstanding status and the collection-workbook check.
- **Roles:** Admin → Mapping → "Operations handlers and collections owners": Preview first; tick "additional person" for a shared role; Edit asks for a reason and keeps the old row; End sets the last day; Withdraw is for a row entered by mistake.
- **Night compaction 29-Oct (one-off):** cancelled during the incident; the `bi-claude-compact-*` jobs were removed from the schedule.

## Cached figures and the 29-Oct incident (wave 097)
- **How caching works now (D191):** `public.bi_call` keys each request; after any data change the last answer is served at once and the request is queued in `bi.api_cache_queue`; cron `bi-api-revalidate` recomputes the queue one request at a time (created as `call bi.api_revalidate(100)` every minute; set to `call bi.api_revalidate(60)` every 5 minutes on 29-Oct while the instance recovers — return to every minute when it is back to normal speed: `select cron.alter_job(jobid, schedule := '* * * * *', command := 'call bi.api_revalidate(100)') from cron.job where jobname = 'bi-api-revalidate';`). Check: `select count(*) filter (where done_at is null) waiting, max(requested_at) last_request, count(*) filter (where last_error is not null) errors from bi.api_cache_queue;`
- **Paused on 29-Oct (D193):** `bi-refresh-point-derived`, `bi-organic-refresh`, `bi-branch-activity`, `bi-warm-drill-cache`, `bi-force-attr-refresh`, `bi-tat-month-stat` (`bi-api-revalidate` was paused too and resumed at 16:05 IST at a slow pace; the one-off `bi-claude-compact-*` jobs were removed). Check speed first: `do $t$ declare t0 timestamptz := clock_timestamp(); n bigint; begin select count(*) into n from generate_series(1, 500000); raise exception '%', clock_timestamp() - t0; end $t$;` (normal well under 0.1 s). Then resume one job at a time, a few minutes apart: `select cron.alter_job(jobid, active := true) from cron.job where jobname = 'bi-api-revalidate';` then the refresh jobs. Leave `bi-warm-drill-cache` paused (the revalidation queue replaces it).
- **API cannot load its schema ("Could not query the database for the schema cache"):** the database is too slow for the API's start-up queries. `authenticator` now has `statement_timeout = 120s` (D192). If it happens again: stop heavy work, then `select pg_terminate_backend(pid) from pg_stat_activity where usename = 'authenticator';` makes the API reconnect.

## Wave 098 (29-Oct-2026 evening) — refresh schedule, stale limit, uploads, Ask timeout
- **Current refresh schedule.** Night (00:30–05:30 IST): `bi-api-revalidate` every 5 minutes (`call bi.api_revalidate(60)`) plus the derived-table refreshes. Day (05:30–00:29 IST): `bi-api-revalidate-light` every 10 minutes (`call bi.api_revalidate_light(20)`) — landing figures only. Do not move the full revalidation into the day on the Free/Nano plan (incident 29-Oct). Check: `select jobname, schedule, active from cron.job order by 1;`
- **Stale limit (D197).** A figure is served from an older data version only when computed in the last 24 h and after the latest `bi.api_cache_floor` row. After a correction of history (month history, retarget, re-import of an old snapshot) add a floor so older figures are recomputed on request: `insert into bi.api_cache_floor(floor_at, reason, set_by) values (now(), '<what changed>', '<who>');` — expect slower first loads of rarely used views until the night run.
- **Uploads (D194).** The Upload Centre says "Imported … confirmed by the server" only after the read-back. "Failed … nothing from this file was saved" means the batch was rejected — upload the file again. "the server did not confirm" means check Admin → Data health (or `select id, status, rows_in from bi.import_batch order by id desc limit 5;`) before uploading again.
- **Ask Crux AI wording (D198).** `bi.ai_config` AI_TIMEOUT_MS = 5000, AI_MAX_RETRIES = 0. When the Gemini quota is used up, answers show "AI service unavailable; showing the calculated answer" — the figures are unaffected. To restore the earlier patience: `update bi.ai_config set value = '20000' where key = 'AI_TIMEOUT_MS'; update bi.ai_config set value = '2' where key = 'AI_MAX_RETRIES';`

## Wave 098b (29-Oct-2026 night) — owner answers
- **Roles (D199).** Operations handler = the location's branch manager / location head on the date (Admin → Mapping → Branch managers); an Admin → Mapping → Roles row overrides it. Collections owner = one row per location (Finance & Collections stakeholder). Zone roll-ups show the zone team managers "(zone teams)".
- **Report calendar (D204).** Admin → Upload Centre → Report calendar: pick a date (past or future), a reason and an optional note, enter your name, Save. Holiday-type reasons make the day a non-working day for run-rate, required per day, working days and ageing; "report missing" reasons keep it a working day. Withdraw (with a reason) keeps the entry, inactive. The Force1 workforce refresh picks up calendar changes at night.
- **Finance updates (D212).** Send Finance the two templates; they change dates and numbers only. Upload the returned files in Admin → Upload Centre. The pre-import panel shows the detected kind and "as on" date; duplicates identical in every field are excluded automatically (D200); a receipts file that only adds new receipts is kept alongside the earlier one (D203).
- **Ageing rule (D209).** Operations → Open cases by age → "Compare the three ageing rules and choose one" (admins): choose, enter your name and a reason, "Use this rule". The change is audited and shows at once (cache floor). Until then: calendar days.
- **Workforce (D208).** Built by cron `bi-person-activity` (01:20 and 04:20 IST) only when Force1 data or the report calendar changed; manual: `select bi.person_activity_refresh();` (~17 s — night only on the Free plan).
- **Cache version (D210).** `bi.cache_version()` is the only definition; any new reader or writer of `bi.api_cache` must call it. Audit actions that start with `ai_`, `kb_`, `job_` and `import_begin` / `import_reject` do not invalidate cached figures.
- **Lumen (D207).** Run `supabase/owner/owner_lumen_removal.sql` step by step in the SQL editor, then delete the `ocr` and `bills` buckets in Storage. The backup (zip) was given to the owner on 29-Oct-2026; it contains a bill PDF and applicant names — keep it private.
- **Storage.** `supabase/owner/owner_storage_cleanup.sql` Step 4 was corrected: it now deletes only cached figures that can no longer be served (older version and over 24 h old or older than the latest floor).
- **After an upload (D214, D215).** Tracker and case counts show within about 10 minutes; Force1 visit, TAT and workforce figures after the night refresh. If an upload stops with "stopped after N of M rows", upload the same file again — saved rows show as unchanged and the rest is added. The daytime refresh (`bi.api_revalidate_light`) always refreshes meta first, then any queued figure that last took under 15 s.

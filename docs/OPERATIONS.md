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
3. Press Import. Rows are staged in chunks, the row count per sheet is checked against the file, and the figures are rebuilt (or within 10 minutes by job `bi-fin-derive`). Re-importing the same file changes nothing.
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
- Owner step: `supabase/owner/owner_storage_cleanup.sql` (about 23 MB). Upgrade or archive decision: SOW Q10/Q19.
- If space is needed again after many re-imports: `vacuum (full, analyze) bi.point_store, bi.case_store;` at a quiet time (locks the tables for about a minute; no data change).

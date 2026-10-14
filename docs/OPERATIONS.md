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
All migrations through `bi_074` are applied (exported automatically to `supabase/migrations/`). When writing new ones, avoid top-level DROP/REVOKE/UPDATE/DELETE — the Supabase connector cancels them; use `create or replace` and guarded `do` blocks. After applying, run `select * from bi.run_acceptance_tests();` (27 tests) and `select * from bi.run_addendum_tests();` (8 tests). New functions in schema `bi` are not reachable by the public key (no schema access); expose them only through `bi_call` (read) or `bi_admin` (write, key required).

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

## Penalties (Business tracker → Penalties)
Admins: date, location, client (optional), amount, reason (required), reference → Add. "Cancel" needs a reason; cancelled penalties stay in the audit trail. Viewers see amounts; reasons are admin-only.

## Organic benchmark
Recomputed by the `bi-organic-refresh` job (every 10 minutes, only when data changed; < 1 s). Manual: `select bi.organic_refresh();`.

## One-time clean-up: retired invoice app
Run `remove_old_invoice_app.sql` (sent separately; not in the repo) in Supabase → SQL Editor, then Storage → "bills" → Delete bucket. It touches only the old app's objects.

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

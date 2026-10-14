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
All migrations through `bi_050` are applied (exported automatically to `supabase/migrations/`). When writing new ones, avoid top-level DROP/REVOKE/UPDATE/DELETE — the Supabase connector cancels them; use `create or replace` and guarded `do` blocks. After applying, run `select * from bi.run_acceptance_tests();` (23 tests). New functions in schema `bi` are not reachable by the public key (no schema access); expose them only through `bi_call` (read) or `bi_admin` (write, key required).

## Business tracker (Zonal Tracker view)
Pick the month at the top, then the snapshot. Levels: Summary / Zones / Locations / All rows (like Excel outline). ▸/▾ collapses a zone or a location block. Click a column header to sort within blocks. "Compare" adds MTD-then, Δ and Δ% columns. "History" adds Actual MTD / Revenue / Billing per past month. "Export to Excel" downloads exactly the rows and columns on screen.

## Master data — client branch lists and the workforce list (Data quality)
1. Unlock with the admin key → Data quality → "Master data". Choose **Client branch master** or **Workforce master** → **Download template** (includes "Read me", valid clients and valid locations).
2. Fill one sheet. Required: branch list — client, branch_code, source, verified_on; workforce — name, role, joining_date, source. Common HR headings (Emp Code, Employee Name, Designation, DOJ, LWD) are recognised. Keep branch codes as Text to preserve leading zeros.
3. Choose the file → **Check file**. Nothing is saved; the result lists every problem with its sheet row (unknown client/location, missing or bad dates, exit before joining, repeated keys).
4. Enter your name → **Import valid rows**. Rows with problems are skipped. Re-uploading updates rows with the same key; uploads never remove rows — mark branches `closed`/`ineligible` or give people an exit date instead.
5. Results: Business tracker → "Branch coverage vs verified client branch list"; People → "Headcount & attrition". Leaver names are visible to admins only.

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
* Add a user: `insert into bi.app_user(email, role) values ('x@cruxindia.co.in','viewer');` (role `admin` to upload/map).
* Remove: `update bi.app_user set active=false where email='x@…';`
* Bulk-load token: create random token, store `encode(digest(token,'sha256'),'hex')` in `bi.ingest_token` with an expiry; revoke after use.

## Hosting options for the standalone app (`web/index.html`)
1. Keep using the Claude artifact (live via each admin's Supabase connector) — works today.
2. GitHub Pages: requires a paid GitHub plan for a private repo, or making the repo public (code only — still safe because data access needs Supabase Auth + approved role).
3. Any static host (Netlify, Cloudflare Pages, Supabase-adjacent hosting).

## Troubleshooting
* "not authorised": the signed-in email is not in `bi.app_user` or not confirmed.
* Upload "Already imported": same file hash already committed.
* Tracker control mismatch warning: the file's own Pan India row disagrees with its leaf rows; leaf rows are used and the mismatch is logged.

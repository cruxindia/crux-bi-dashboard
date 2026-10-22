# Supabase utilisation and storage audit

Project `czdjbbhxboweawqbjywr` (free plan). Measured on 14-Oct-2026 from the live database with `pg_total_relation_size`, `pg_stat_user_tables`, `pg_stat_user_indexes`, `pg_stat_statements`, `pg_depend`/`pg_rewrite`, function source text, `cron.job` and `storage.objects`. Sizes include indexes and TOAST unless stated.

## 1. Headline

| Metric | Value |
|---|---|
| Free-plan database limit | 500 MB. Over the limit the project becomes **read-only** and cron jobs stop ([Supabase docs](https://supabase.com/docs/guides/platform/database-size)) |
| Database `postgres` before this audit | 428 MB (448,457,875 bytes) |
| Database `postgres` after safe cleanup | 413 MB (432,958,611 bytes) — **15.5 MB reclaimed** |
| All databases (Supabase's own measure sums `template0/1`, about 7 MB each) | about 427 MB right after cleanup; 450,187,441 bytes (429 MiB) at the end of the session |
| Object storage | 10.5 MB in 6 files in the public bucket `ocr` (OCR engine of the Lumen bill extractor — in use); bucket `bills` holds Lumen's bill files (empty after the 14-Oct clean-up) |
| Growth rate (measured) | Force1 visits about 105–113 k rows per month since Jun-2026 (`point_store` + `point_derived` ≈ 320 bytes per visit), plus about 30 k cases per month → **about 40 MB per month** |
| Projected read-only date at current growth | **between mid-November and early December 2026**: about 50 MB of headroom if Supabase counts the limit as 500,000,000 bytes, about 74 MB if it counts 500 MiB, at roughly 43 million bytes per month. The owner script in §6 adds about two weeks. |

The main pressure is not waste: 72% of the database is raw Force1 visit and case history plus one derived cache of it. Cleanup alone cannot keep the project on the free plan for long. A decision is needed (see §7).

## 2. Inventory (schema `bi`, 51 tables, 1 materialized view, 10 views, 112 functions (+42 in `public`, of which 11 are the RPC entry points and helpers listed in OPERATIONS.md), 7 cron jobs, 2 Edge Functions)

Other schemas: `pg_catalog` 13 MB, `storage` 1.8 MB, `auth` 1.1 MB, `supabase_migrations` 0.4 MB, `realtime` 0.3 MB, `cron` 0.2 MB (359 run records), `vault`/`net` empty. Not touched: these are Supabase internals or migration history.

| Object | Rows | Total MB | Index MB | Category | Dependency evidence (source → function → capability) | Recommendation |
|---|---:|---:|---:|---|---|---|
| point_store | 751,902 | 154.1 | 36.0 | 3 | raw Force1 visits → `fact_point` → `v_point` → `refresh_point_derived`, `refresh_employee_classification`, `api_point_tat`, `api_employees` → Force1 utilisation, TAT, People | Retain (authoritative history). Archive policy only by owner decision (§7) |
| point_derived | 751,902 | 86.3 | 26.2 | 2 | rebuilt from `v_point` by `refresh_point_derived` (cron every 10 min, only when stale) → `api_force1`, `api_attrition`, `bi_ask` | Retain; drop unused PK index (21 MB, §6) |
| client_branch_master | 91,675 | 48.8 | 11.5 | 4 | branch research → `branch_admin` (monitor), `api_branch_coverage`, `api_branches`, `api_branch_research`, `api_meta` → Business tracker coverage, Data quality | Retain (authoritative master) |
| case_store | 213,472 | 39.8 | 10.6 | 3 | raw Force1 cases → `fact_case` → `v_case`, `v_force_usage` → overview, TAT, lifecycle, `branch_activity_refresh`, `live_locations`, `bi_ask` | Retain |
| client_branch_history | 96,508 | 15.1 | 5.8 | 3 | effective-dated master history (91,675 first-observed, 4,801 status changes, 32 territory changes) → `branch_admin` | Retain (required by addendum §1.3) |
| branch_cov_mv | 90,165 | 14.5 | 5.4 | 2 | materialized view of master → `api_branch_coverage`; refreshed by `run_finish` | Retain; drop unused unique index (2.7 MB, §6) |
| zt_row | 58,905 | 11.4 | 3.2 | 1 | daily Zonal Tracker → `v_zt_leaf` → `v_month_business`, `v_zt_daily` → 20+ API functions, daily table (`matrix_*`) | Retain |
| branch_seen | 91,675 | 9.5 | 3.6 | 4 | last run in which each branch was seen → monitor "no longer listed" check | Retain |
| api_cache | 202 | 5.5 | 0.0 | 2 | `bi_call` response cache keyed on `audit_log` version; one row per request shape (overwritten, not appended) | Retain (rebuilds itself) |
| organic_store | 10,976 | 3.1 | 0.8 | 2 | `organic_refresh` → `organic_get` → organic expectation in tracker, potential, growth | Retain |
| audit_log | 2,864 | 1.0 | 0.1 | 3 | every admin change; its max id is the cache version | Retain |
| employee, dim, zt_month_history, dq_exception, branch_review, branch_activity, location_territory, zt_matrix_draft, import_batch | 100–8,100 each | 0.2–1.0 each | — | 1–4 | reference data, daily-table drafts, imports, exceptions, review queue | Retain |
| kb_doc / kb_chunk | 77 / 77 | 0.5 | — | 4 | RAG definitions, `gemini-embedding-2` vectors (768) | Retain |
| ai_conversation / ai_message / ai_provider_usage / ai_model_check / ai_config | 49 / 56 / 109 / 12 / 10 | 0.5 | — | 4 | Ask Crux history, usage log, model validation | Retain (small) |
| repo_file, export_token | 17 / 1 | 0.3 | — | 2 | deployment stash → GitHub workflow | Retain |
| ingest_token, app_user | 6 / 1 | <0.1 | — | 2 | admin and job authentication | Retain |
| stg_row | 0 | <0.1 | — | 6 | import staging, emptied after each commit | Retain (empty) |
| zt_snapshot_archive | 0 | 0.1 | — | 3 | copy of a snapshot before a daily-table overwrite (recovery) | Retain |
| workforce_master, penalty, rate_change, zt_reopen, report_calendar_exception | 0 | <0.1 each | — | 1 | live features waiting for data (attrition, penalties, rate changes, re-open, no-report days) | Retain |
| Views `fact_case`, `fact_point`, `v_case`, `v_case_coverage`, `v_force_usage`, `v_latest_snapshot`, `v_month_business`, `v_point`, `v_zt_daily`, `v_zt_leaf` | — | 0 | — | 1–2 | see dependency column above | Retain |

Categories: 1 dashboard, 2 indirect/derived, 3 history/audit/recovery, 4 AI/RAG/branch research/background, 5 redundant, 6 stale staging, 7 no usage found, 8 inconclusive. No object fell into 5, 7 or 8: every table is referenced by at least one function or view, and every function chain ends in an RPC used by the dashboard, Ask Crux, a cron job or an Edge Function. No RLS policies exist on `bi` tables because the schema is not exposed; all access goes through `SECURITY DEFINER` RPCs.

### Indexes

| Index | MB | Scans | Backs a constraint | Finding |
|---|---:|---:|---|---|
| point_derived_pkey | 21.0 | 0 at audit time; 1 after the independent review's checks | primary key | No production lookup by `point_id` found in function source; the table is rebuilt by TRUNCATE + INSERT. Low-risk to drop after re-checking the counter (§6) |
| branch_cov_mv_key | 2.7 | 0 at audit time; 4 after test runs | no | Used by test queries; only 2.7 MB — **keep** |
| client_branch_history_pkey | 2.1 | 0 | primary key | Keep: row identity for history |
| point_store_case_id_idx | 9.7 | 170 | no | Keep: low-frequency but used |
| point_store_created_month_recon_unit_idx, point_store_verified_by_id_idx | 5.1 each | 72 / 187 | no | Keep: used by monthly refreshes |
| Small zero-scan PK/unique indexes (location_territory, location_alias, client_alias, location code, ai_model_check, app_user, branch_review, zt_snapshot_archive) | <0.1 each | 0 | yes | Keep: constraints |

### Scheduled and server-side writers

| Job / function | Schedule | Writes |
|---|---|---|
| bi-refresh-point-derived | every 10 min (no-op unless visits changed) | point_derived, employee |
| bi-organic-refresh | every 10 min (no-op unless snapshot changed) | organic_store |
| bi-wef-sync | daily 18:35 UTC | location (WEF-dated groups) |
| bi-branch-activity | :07 and :37 each hour (no-op unless cases changed) | branch_activity |
| bi-branch-monitor | 2nd of each month, every 10 min 01:00–03:50 UTC until complete | client_branch_master, branch_seen, history, review, job_run, branch_cov_mv |
| bi-ai-validate | 2nd of each month 03:50 UTC | ai_model_check, ai_config |
| bi-ai-embed-sync | daily 02:20 UTC | kb_chunk embeddings (only pending chunks) |
| Edge Function ask-crux | on request | ai_message, ai_provider_usage |
| Edge Function branch-monitor | via cron | as bi-branch-monitor |

`pg_stat_statements` is enabled; PostgREST wraps every RPC in the same statement text, so per-endpoint call counts are not separable. Usage was therefore established from function source references, view dependencies and the Playwright workflow tests, not from query counters alone.

## 3. Cleanup performed (14-Oct-2026)

| Step | Evidence | Result |
|---|---|---|
| `VACUUM FULL` on client_branch_master, branch_seen, zt_row, api_cache, kb_chunk, job_run, branch_review, ai_message, import_batch, zt_snapshot, location_mapping_history, location_alias, repo_file | 4,801 / 7,766 / 11,527 dead tuples on the first three; bloated TOAST on api_cache | 428 → 413 MB. No rows removed. Overview, Force1, tracker, coverage and research endpoints re-checked afterwards; full acceptance and UI tests re-run (TEST_REPORT.md) |
| Earlier today: lean branch storage (narrow `branch_seen`, master updated only on change, no duplicate history copies) | DB had reached 414 MB during the first branch load | Branch footprint held at about 88 MB for 91,675 branches |
| Earlier today (owner-run script): retired invoice-app tables removed | owner confirmed "Sql run done"; tables verified absent | database measured 319 MB right after it ran (before the branch master was loaded) |

Rows deleted by me: none. The database connector used for this work refuses any statement containing DELETE, DROP, TRUNCATE or REVOKE, so every removal is handed to the owner as a script instead of being worked around.

## 4. Cleanup recommended, not performed

| Item | Saving | Risk | Why not done here |
|---|---:|---|---|
| Drop `point_derived_pkey` | 21 MB | Low — uniqueness already guaranteed by `point_store` PK; re-check the scan counter first | needs DROP; owner script §6 |
| ~~Delete buckets `ocr` and `bills`~~ | — | **Withdrawn 15-Oct: both are used by the Lumen bill extractor** (SOW D84); the earlier "no code references" check only looked at the BI code | Do not delete |
| Compact the 91,675 "first observed" history rows into the master's `first_observed` column | about 12 MB | Medium — loses per-branch source version of the first sighting | history is an addendum requirement; only if pressure remains after §7 |

## 5. Not recommended

Raw `point_store` and `case_store` history, `zt_row`, `audit_log`, mappings, Ask Crux history and embeddings are retained: they are the only source for historical reports, reconciliation and recovery, and the embeddings are 0.4 MB.

## 6. Owner script

`owner_storage_cleanup.sql` (sent with this report) runs a dry-run check (including the index scan counter), drops the unused `point_derived` primary-key index with a rollback line, and re-checks the coverage and Force1 endpoints. Expected: about 21 MB.

## 7. Decision needed: staying under 500 MB

At about 40 MB of new Force1 data per month, the project reaches the free-plan limit between mid-November and early December 2026 even after §6. Options:

1. **Upgrade to Pro** — from $25 per month with 8 GB disk per project, then $0.125 per GB ([Supabase pricing](https://supabase.com/pricing)). No code change; removes the risk for several years at the current rate.
2. **Archive raw visit history** older than a chosen window (for example 6 months) to a compressed file in Storage, keeping monthly aggregates in the database. Saves about 35 MB per archived month but loses drill-down to individual visits for archived months unless restored. Needs a design and a tested restore path before any data leaves the database.
3. **Both**: upgrade now, design archiving later.

Option 1 or 3 is recommended. Nothing irreversible is done until the owner chooses.

## 8. Re-measure — 15-Oct-2026 (corrective wave)
| Measure | 14-Oct after cleanup | 15-Oct before | 15-Oct after safe actions |
|---|---:|---:|---:|
| Database `postgres` (bytes) | 432,958,611 | 446,475,411 | **439,667,859** |
| All databases (bytes) | 450,187,441 (end of 14-Oct) | 461,590,705 | **454,783,153** |
| Headroom to 500,000,000 bytes | — | 38.4 MB | **45.2 MB** (69.5 MB if the limit is 500 MiB) |

**Where the +13.5 MB came from (14-Oct cleanup → 15-Oct):** `branch_seen` 9.5 → 18.6 MiB (every monitor run rewrites one row per branch; two runs left a dead copy of each row and a bloated index), `zt_row` +1.1 MiB (rolled-back test updates), branch master/history +0.5 MiB (wave-3 research rows), the rest small (functions, cache, AI messages). No new Force1 upload in this period; `point_store` / `point_derived` unchanged.

**Safe actions taken (no rows removed):** `VACUUM FULL` on `zt_row` (−1.2 MB) and `api_cache` (−2.6 MB); `branch_seen` set to fillfactor 50 then `VACUUM FULL` (−3.0 MB; later monitor runs update in place, so the index stops growing) — `bi_081`. Total **−6.8 MB**. Row counts checked before/after (58,905 / 236 / 92,239); all SQL suites and browser suites re-run afterwards.

**Owner items — status 15-Oct:** `owner_storage_cleanup.sql` **not run** (`point_derived_pkey` still present, 21 MB; its scan counter now shows 1 scan, so re-check before dropping); buckets `ocr` and `bills` belong to the Lumen bill extractor and must stay (D84).

**Forecast:** at about 40 MB of Force1 data per month the database reaches 500,000,000 bytes around **mid-November 2026** (early December if the limit is 500 MiB or after the owner script). The §7 decision (Pro plan or archive design) is now urgent.

**Dry run of the remaining options (nothing executed):**
| Option | Gain | Risk / recovery |
|---|---:|---|
| Owner script: drop `point_derived_pkey` | ~21 MB | Low; script has a dry-run check and a re-create line |
| ~~Delete buckets `ocr`, `bills`~~ | — | Withdrawn: used by the Lumen app (D84) |
| Compact `client_branch_history` first-observed rows | ~12 MB | Medium; loses per-row source version of first sighting |
| Archive visit history older than 6 months | ~35 MB per month archived | Needs design + tested restore before any data leaves |
| Upgrade to Pro (8 GB) | removes the limit | Cost; no data risk |


## 9. Live re-measure, root cause and cleanup — 21-Oct-2026 (evening)

Measured 21-Oct-2026 17:25 UTC (22:55 IST) with `pg_database_size`, `pg_total_relation_size`, `pg_relation_size`, `pg_indexes_size`, `pgstattuple_approx` and `pgstatindex` (the `pgstattuple` extension was added for this, read-only diagnostics). The historical notes above are kept for history; they are not the current size.

### 9.1 Which figure counts

| Figure | Bytes | What it is |
|---|---:|---|
| **Supabase database size (all databases)** | **534,827,185** (510.1 MiB) | The figure the Free-plan 500 MB read-only limit applies to ([Supabase docs](https://supabase.com/docs/guides/platform/database-size)): `postgres` + `template0` + `template1` |
| Project database `postgres` only | 519,711,891 | Some earlier notes quoted this one — about 15 MB lower |
| Repository notes (14-Oct 413 MB, 15-Oct 439.7 MB, 21-Oct morning 476.6 MB) | — | Stale measurements, not the live size |
| File storage (buckets `ocr` 6 files, `bills` 1 file — Lumen) | 11,075,631 | Not part of the database size |
| Disk (1 GB on Free) | — | Separate; includes WAL. Not the limit that triggers read-only |

Supabase's usage pages refresh daily, so the dashboard can lag behind the live figure. The project was **not** read-only at the time (`default_transaction_read_only = off`).

### 9.2 Size-ranked audit (before cleanup)

| Table | Total MB | Heap | Indexes | TOAST | Rows | Free heap | Finding |
|---|---:|---:|---:|---:|---:|---:|---|
| point_store | 195.6 | 150.1 | 45.4 | 0.0 | 785,150 | 21.8 MB (14.5 %) | Raw Force1 visits (authoritative). Index leaf density 68–83 % |
| point_derived | 94.7 | 65.9 | 28.8 | 0.0 | 785,150 | 0.2 MB | Rebuildable cache (TRUNCATE + INSERT). Primary-key index 23.1 MB, no reader in any function |
| case_store | 61.2 | 44.3 | 16.8 | 0.0 | 227,249 | 11.7 MB (26.5 %) | Raw Force1 cases (authoritative). Index leaf density 51–60 % |
| client_branch_master | 51.5 | 39.4 | 12.1 | 0.0 | 92,239 | 0.8 MB | Verified branch master (authoritative) |
| branch_seen | 16.6 | 12.8 | 3.8 | 0.0 | 92,239 | 6.5 MB | Fill factor 50 on purpose (monitor updates in place) |
| client_branch_history | 15.9 | 9.7 | 6.2 | 0.0 | 96,955 | 0.1 MB | Effective-dated history (required) |
| branch_cov_mv | 15.2 | 9.4 | 5.7 | 0.0 | 90,714 | — | Materialised view (rebuildable) |
| zt_row | 13.7 | 9.9 | 3.8 | 0.0 | 63,465 | 0.6 MB | Daily tracker rows (authoritative) |
| api_cache | 8.2 | 1.4 | 0.1 | 6.6 | 1,084 | — | Response cache, one row per request shape (rebuilds itself) |
| organic_store | 3.6 | 2.6 | 0.9 | 0.0 | 13,272 | 1.2 MB | Organic model output (rebuildable) |
| stg_row | 2.8 | 0.0 | 2.8 | 0.1 | 0 | — | Empty import staging with a bloated index |
| fin_part | 2.7 | 0.0 | 0.0 | 2.7 | 49 | — | Compressed finance rows (evidence) |
| All other `bi` tables | ≈ 13 | | | | | | Reference, audit, AI, finance aggregates |
| All indexes in `bi` | 131.2 | | | | | | |

### 9.3 Root cause of the jump (476.6 → 519.7 MB on 21-Oct)

Every re-import of a month's Case Wise / Point Wise file rewrote **every row, even unchanged ones**: `commit_point` upserted unchanged points and then updated `recon_unit` again (2 new row versions per point); `commit_case` and `relocate_cases` did the same three times per case. Vacuum makes the dead versions reusable but the files stay large. Evidence: since the 06:57 UTC restart, point_store had 143,432 updates for 8,388 inserts and case_store 63,823 updates for 2,617 inserts (the October files were re-imported at 16:32 IST); a rolled-back production test re-imported the same 30 points and 30 cases twice — the old code rewrote 30/30 each time with no value change.

### 9.4 Actions taken (no rows removed)

1. **bi_091b** — trigger `zz_skip_noop_update` (BEFORE UPDATE on point_store and case_store) skips an update when nothing but `last_batch` would change. Stored values are identical to before; `last_batch` now means "batch that last changed the row". Tested in a rolled-back transaction on production data: identical re-import 0/30 rewritten (was 30/30), 0 value differences; a real change (5 points, 4 cases) still applied; a date change still recomputes the generated month. Rollback: `alter table bi.point_store disable trigger zz_skip_noop_update; alter table bi.case_store disable trigger zz_skip_noop_update;`
2. **VACUUM FULL ANALYZE** (rewrites a table without its dead space; no data change) — row counts and a checksum of every whole row were taken before and after and are identical:

| Table | Before (bytes) | After (bytes) | Freed |
|---|---:|---:|---:|
| point_store | 195,600,384 | 168,697,856 | 26,902,528 |
| case_store | 61,227,008 | 42,827,776 | 18,399,232 |
| stg_row | 2,842,624 | 16,384 | 2,826,240 |
| organic_store | 3,563,520 | 1,884,160 | 1,679,360 |
| zt_month_history | 1,998,848 | 974,848 | 1,024,000 |
| employee | 1,024,000 | 376,832 | 647,168 |
| branch_review | 1,056,768 | 557,056 | 499,712 |
| branch_activity | 925,696 | 450,560 | 475,136 |
| dq_exception | 589,824 | 393,216 | 196,608 |
| **All databases (Supabase measure)** | **534,827,185** | **482,242,737** | **52,584,448** |
| Project database `postgres` | 519,711,891 | 467,127,443 | 52,584,448 |

### 9.5 Candidates not executed, with their size and the reason

| Candidate | Size | Risk | Why not done here |
|---|---:|---|---|
| Drop `point_derived_pkey` (owner script `supabase/owner/owner_storage_cleanup.sql`) | 23.1 MB | Low: no function reads point_derived by point_id, uniqueness comes from point_store's key; re-create line included | Index removal is a DROP, which this connection does not run |
| Compute Force1 views from point_store and retire point_derived | up to ≈ 95 MB | Medium: api_force1, api_attrition, api_drill_ops and Ask Crux read it; performance must be re-tested | Needs a design and a performance test first |
| Archive visit history older than N months to file storage | ≈ 35 MB per archived month | Medium/high: drill-down to individual visits of archived months needs a restore | Needs an owner decision and a tested restore |
| Upgrade to Pro (8 GB included) | removes the limit | None for data | Owner decision (cost) |
| Not recommended | — | — | Raw case/visit history, tracker rows, mappings, audit log, finance evidence, the response cache (8 MB, rebuilds itself), branch_seen's fill factor |

### 9.6 Forecast after cleanup

New Force1 data adds **about 42.2 MB per month** (average of the last three complete months: ≈ 110 k visits at 336 bytes including the derived cache and indexes, plus ≈ 31 k cases at 188 bytes). Headroom is 17.7 MB to 500,000,000 bytes (≈ **13 days → about 3-Nov-2026**), or 41.9 MB if Supabase counts 500 MiB (≈ 30 days). The owner script adds about 16 days. The Pro-plan or archive decision (SOW Q10/Q19) is therefore urgent. Admin workspace → Database health shows these figures live.

## 10. Re-audit and safe remediation — 22-Oct-2026 (wave 092)
Measured live with `pg_database_size` (all databases = the Free-plan figure), `pg_total_relation_size`, `pgstattuple_approx`, `pgstatindex`. Plan: **Free** (organisation plan checked 22-Oct); project `ACTIVE_HEALTHY`, not read-only (`default_transaction_read_only = off`).

| When (UTC, 22-Oct) | All databases (bytes) | `postgres` (bytes) | Note |
|---|---:|---:|---|
| 03:59 — start of this wave | 482,996,401 | 467,881,107 (derived: all − templates 15,115,294) | after the 21-Oct cleanup + overnight growth |
| 04:50 — before remediation | 486,453,425 (derived: postgres + templates) | 471,338,131 (measured) | migrations, finance re-derive, cache entries and test fixtures of this wave (+3.5 MB) |
| 04:52–04:53 — after VACUUM FULL / REINDEX | **475,697,329** (04:53) | 460,573,843 (04:52) | **−10,764,288 bytes** on `postgres`, measured immediately before (471,338,131) and after |
| 05:07 — after plain `vacuum (analyze)` and new cache entries | 476,909,745 | 461,794,451 | visibility maps rebuilt (+0.3 MB); response cache refilled after the API change |
| 05:16 — after the scheduled jobs rebuilt `point_derived`, `organic_store`, `employee`, `branch_activity` | **484,896,945** | — | my cache-invalidation row (action `api_change`, 05:09) marked the derived tables stale; their rebuild undid ≈ 8 MB of the compaction (see below) |

**Actions taken (no rows removed, all reversible by nature):**
| Object | Before (bytes) | After (bytes) | Freed | Why it was safe |
|---|---:|---:|---:|---|
| `point_derived_pkey` (REINDEX) | 22,945,792 | 17,661,952 | 5,283,840 | leaf density 69 %, fragmentation 50 %; same index rebuilt. It grows back at the next full rebuild of `point_derived` (TRUNCATE + INSERT in non-key order) — the owner script removes it for good |
| `organic_store` (VACUUM FULL) | 3,530,752 | 1,884,160 | 1,646,592 | 45 % free space; rebuildable model output |
| `api_cache` (VACUUM FULL) | 8,527,872 | 7,143,424 | 1,384,448 | 20 % free space + dead rows; cache |
| `zt_row` (VACUUM FULL) | 13,991,936 | 12,861,440 | 1,130,496 | 7 % free + 2,522 dead rows; row count 63,465 before and after |
| `fin_review` (VACUUM FULL) | 1,048,576 | 532,480 | 516,096 | dead rows; 1,027 rows before and after |
| `branch_activity` (VACUUM FULL) | 892,928 | 450,560 | 442,368 | 50 % free; 4,296 rows before and after |
| `employee` (VACUUM FULL) | 745,472 | 376,832 | 368,640 | 50 % free; 686 rows before and after |
| `branch_seen` (VACUUM FULL) | 16,564,224 | 16,564,224 | 0 | Fill factor 50 is deliberate (monthly monitor updates in place) — left as is |

Row counts were checked after the rewrite (92,239 / 13,272 / 63,465 / 686 / 4,296 / 1,127 / 1,027 / 785,150). Follow-up found by the admin browser test: VACUUM FULL leaves the visibility map empty, which made `api_db_health` read whole tables (15 s → the Database health page failed to load); a plain `vacuum (analyze)` of the large tables fixed it (0.9 s). This is now in OPERATIONS.md.

**What lasted — honest result.** Compaction is durable only for tables written by imports. `point_derived_pkey` (back to 23,379,968 bytes), `organic_store` (3,530,752), `employee` (745,472) and `branch_activity` (892,928) are rebuilt by scheduled jobs and returned to their earlier size within 20 minutes, triggered by the audit row this wave inserted to invalidate the response cache (the cache-only action `cache_bump` should have been used — now in OPERATIONS.md). Durable gains: `zt_row` −1.10 MB, `fin_review` −0.48 MB. Net over the wave: 482,996,401 → 484,896,945 bytes (+1.9 MB: this wave's functions, finance re-derive and refilled response cache outweigh the durable compaction). A second REINDEX of `point_derived_pkey` was attempted at 05:16 and cancelled by the statement timeout while the cache warm-up job held the table — not retried (it would also block readers while waiting). The levers that last are the owner script (index drop ≈ 23 MB, stale cache ≈ 5.9 MB) and, if the key is kept, inserting `point_derived` rows in key order (needs an owner change to `refresh_point_derived`, which contains TRUNCATE and cannot be redefined from this connection).

**Duplicate import prevention (finance):** a re-saved copy of an imported workbook is refused before staging (browser content hash) or rejected at commit (server content hash) — previously such a copy would have stored another ≈ 2.7 MB of `fin_part` rows. Verified live by `test_fin_ui` A5b and by fixtures F01/F02.

**Largest objects now** (bytes, total incl. indexes): point_store 168.8 M (raw visits, authoritative) · point_derived 89.3 M (rebuildable cache) · client_branch_master 51.5 M (authoritative) · case_store 42.9 M (raw cases) · branch_seen 16.6 M · client_branch_history 15.9 M (history, required) · branch_cov_mv 15.2 M (rebuildable) · zt_row 12.9 M (tracker rows) · api_cache 7.6 M (cache) · fin_part 2.8 M (finance evidence). All `bi` indexes: 109.3 M.

**Not done, with the precise blocker:**
| Candidate | Size | Blocker / reason | Supported path |
|---|---:|---|---|
| Drop `point_derived_pkey` | 17.7 MB now, ≈ 23 MB after each rebuild | DROP is refused by this connection | Owner runs `supabase/owner/owner_storage_cleanup.sql` step 1 (dry-run check and re-create line included) |
| Remove response-cache rows of old versions | ≈ 5.9 MB (1,032 rows on 22-Oct) | DELETE is refused by this connection (rewriting payloads instead would be a work-around, so not done) | Owner script step 3, then `vacuum (full, analyze)` + `vacuum (analyze)` |
| pg_cron run history | < 1 MB | DELETE refused | Owner script step 4 |
| Retire `point_derived` (compute from `point_store`) | up to ≈ 89 MB | Design + performance test needed (api_force1, api_attrition, api_drill_ops, Ask Crux read it) | SOW Q10/Q19 |
| Archive old visit history | ≈ 35 MB per month archived | Owner decision and tested restore | SOW Q10/Q19 |
| Not candidates | — | Audit log, raw case/visit history, tracker rows, finance uploads and parts (evidence), invoice/receipt identity, mapping history, branch master/history | Kept |

**Headroom and forecast:** 484.9 MB (all databases, 05:16 UTC) → 15.1 MB below 500,000,000 bytes, 39.4 MB below 500 MiB. At ≈ 42 MB of new Force1 data per month that is about **11 days (≈ 2-Nov-2026)**, or ≈ 28 days if the limit is 500 MiB. The owner script (≈ 29 MB) adds about 3 weeks. The Pro-plan or archive decision is urgent.

# Supabase utilisation and storage audit

Project `czdjbbhxboweawqbjywr` (free plan). Measured on 14-Oct-2026 from the live database with `pg_total_relation_size`, `pg_stat_user_tables`, `pg_stat_user_indexes`, `pg_stat_statements`, `pg_depend`/`pg_rewrite`, function source text, `cron.job` and `storage.objects`. Sizes include indexes and TOAST unless stated.

## 1. Headline

| Metric | Value |
|---|---|
| Free-plan database limit | 500 MB. Over the limit the project becomes **read-only** and cron jobs stop ([Supabase docs](https://supabase.com/docs/guides/platform/database-size)) |
| Database `postgres` before this audit | 428 MB (448,457,875 bytes) |
| Database `postgres` after safe cleanup | 413 MB (432,958,611 bytes) — **15.5 MB reclaimed** |
| All databases (Supabase's own measure sums `template0/1`, about 7 MB each) | about 427 MB right after cleanup; 450,187,441 bytes (429 MiB) at the end of the session |
| Object storage | 10.5 MB in 6 files, all in the public bucket `ocr` (retired invoice app); bucket `bills` is empty |
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
| Delete bucket `ocr` (public, retired app) and empty bucket `bills` | 10.5 MB object storage (not database) | Low — no code references either bucket | Dashboard action |
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

**Owner items — status 15-Oct:** `owner_storage_cleanup.sql` **not run** (`point_derived_pkey` still present, 21 MB; its scan counter now shows 1 scan, so re-check before dropping); bucket `ocr` (public, 6 files, 10.5 MB) and empty bucket `bills` **still exist**.

**Forecast:** at about 40 MB of Force1 data per month the database reaches 500,000,000 bytes around **mid-November 2026** (early December if the limit is 500 MiB or after the owner script). The §7 decision (Pro plan or archive design) is now urgent.

**Dry run of the remaining options (nothing executed):**
| Option | Gain | Risk / recovery |
|---|---:|---|
| Owner script: drop `point_derived_pkey` | ~21 MB | Low; script has a dry-run check and a re-create line |
| Delete buckets `ocr`, `bills` | 10.5 MB object storage (not the DB limit) | Low; download the 6 files first if wanted |
| Compact `client_branch_history` first-observed rows | ~12 MB | Medium; loses per-row source version of first sighting |
| Archive visit history older than 6 months | ~35 MB per month archived | Needs design + tested restore before any data leaves |
| Upgrade to Pro (8 GB) | removes the limit | Cost; no data risk |


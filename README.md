# Crux Business Intelligence — Zonal Tracker × Case Wise × Point Wise

One analytical system that connects the three operational sources:

| Level | Source | Grain | Role |
|---|---|---|---|
| 1 | Zonal Tracker (`Main Tracker` sheet only) | location × client × daily snapshot; monthly history | **Authoritative business count**, targets, revenue |
| 2 | Case Wise (Force MIS) | one row per case | Force usage, case TAT, SLA |
| 3 | Point Wise (Force MIS) | one row per verification point | field / document / tele TAT, workload, people |

**No business data is stored in this repository.** Data lives in Supabase (schema `bi`).

**Access model (decided 12-Oct-2026):** the dashboard is public and needs no login (read-only, `noindex`). Uploads, mapping edits and exception details require an **admin key** (time-limited token; only its SHA-256 hash is stored).

## Architecture
```
xlsx files ──► web/extract.js (browser or Node; strips PII) ──► public.bi_ingest RPC
                                                              └─► bi.stg_row ─► bi.commit_* (dedup, upsert, aliasing, DQ)
bi.fact_case / bi.fact_point / bi.zt_row / bi.zt_month_history ─► bi.v_* views ─► bi.api_* functions
                                                                                     │
          dashboard (web/index.html, GitHub Pages) ◄── public.bi_call (anonymous read, cached per data version)
          admin functions                          ◄── public.bi_admin / bi_ingest (admin key)
```
* All calculations are in SQL (`bi.api_*`, `bi.v_*`); the UI only formats.
* Structure interpretation of the tracker lives only in `web/extract.js`, shared by the browser Upload Centre and the bulk loader.
* Raw tables are never exposed to the API: schema `bi` is not granted to `anon`/`authenticated`; only `public.bi_call`, `bi_admin`, `bi_ingest`, `bi_repo_export` are callable and each checks authorisation.

## Repository
| Path | What |
|---|---|
| `supabase/migrations/` | Exact SQL applied to the project, in order (auto-exported) |
| `web/index.html` | Dashboard + Upload Centre (standalone, Supabase Auth) |
| `web/index.src.html` | Source template (build injects libraries) |
| `web/extract.js` | Shared extractor (tracker structure, PII stripping, UTC handling) |
| `tools/extract-all.js`, `tools/loader.js` | Bulk historical load (resumable, idempotent) |
| `docs/` | SOW, data dictionary, metric dictionary, test report, operations guide, limitations |
| `.github/workflows/sync.yml` | Re-assembles this repo from the code-only export channel |

## Setup (new environment)
1. Create a Supabase project; apply `supabase/migrations/*.sql` in filename order.
2. Create an admin key: random string; store `encode(extensions.digest(key,'sha256'),'hex')` in `bi.ingest_token` with an expiry.
3. Set `alter role anon set statement_timeout='20s'` (done by migration bi_021).
4. Set `CFG.url` / `CFG.key` (publishable key only) in `web/index.src.html`, then serve `web/` from any static host.
5. Bulk history: put files in `src/<zonal|case|point>/`, run `node tools/extract-all.js <kind>` then `node tools/loader.js <kind>` with `.env` values.

## Deployment status
* Database: Supabase project `czdjbbhxboweawqbjywr` (`bi` schema) — live, loaded, tests passing.
* Dashboard: GitHub Pages, deployed by `.github/workflows/sync.yml` from `web/` (no login).
* Storage: compact integer-coded stores (`bi.case_store`, `bi.point_store`) behind same-named decoding views; DB ≈195 MB (was 401 MB).

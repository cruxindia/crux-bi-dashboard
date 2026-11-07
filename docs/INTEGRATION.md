# Connecting another tool to the dashboard (wave 100, 7-Nov-2026)

The owner's new tool runs on GitHub, keeps its data in its own Supabase project, and brings in Zonal Tracker information and
more. This note explains how to connect it to the Crux BI dashboard safely. It contains no keys or tokens.

> **Update 7-Nov-2026 18:39 IST — the owner chose full unification (option D, one product).** The new tool's Claude chat takes over as the development platform: it audits the tool first (fitment, opportunities, user experience, dashboard integration, UI/UX), then designs one Supabase project in the operations.alert@cruxindia.com organisation with one database (no duplicated tables or data), one logic layer, one login with role-scoped data, and the tool's data as the primary source. The Force1 Case Wise / Point Wise uploads and the Zonal Excel upload stay live until the tool's MTD equals the Excel for every location × client on 10 consecutive working report days including a month-end (D233). The role prompt, technical pack and deck were handed to the owner directly; they hold business figures and are not in this repository. Options A–C below remain valid for the transition period only.

## What exists on the dashboard side

- **One database** (Supabase project `czdjbbhxboweawqbjywr`, schema `bi`). Every figure on the pages is computed there and served through `public.bi_call` with a response cache.
- **One way in for data**: `public.bi_ingest(token, action, payload)`. This is the same path the Upload Centre uses. Each upload is a batch (`begin` → pieces → `commit`). A batch is checked, saved, audited (`bi.audit_log`) and then refreshes the cached figures. A failed batch is rejected with a reason.
- **Least-privilege tokens** (bi_100j). A token with scope `ingest` can call `bi_ingest` and nothing else. It cannot use admin functions or settings, and it cannot read admin-only views. Tokens are stored only as SHA-256 hashes in `bi.ingest_token`. Each token has a label and an expiry, and can be revoked.

## Options

| Option | How it works | For | Against |
|---|---|---|---|
| **A. The tool pushes (recommended)** | When the tool has a new tracker snapshot, its server side sends it to `bi_ingest` with an `ingest` token. | The same checks, audit trail and cache refresh as a manual upload. Nothing reaches into the tool's database. Easy to switch off by revoking the token. | Needs server-side code in the tool: a Supabase Edge Function, a database webhook or a GitHub Action. |
| B. The dashboard pulls | A scheduled Edge Function here reads the tool's tables with a read-only key, then calls `bi_ingest`. | Works if the tool cannot run code. | The tool's key is stored here as a secret. A schema change in the tool breaks the pull. |
| C. Database link (postgres_fdw / Supabase Wrappers) | Foreign tables point at the tool's database. | Live. | Couples two databases, and a slow remote query slows the pages. Credentials sit inside the database. Not suited to the current plan. |
| D. One project | Move the tool's tables into this project, in their own schema. | One source of truth. | The project is already above the 500 MB free quota (OD-022), so do this only after the plan decision. |
| E. Links only | The dashboard links to the tool's pages. | No data work. | No combined figures. |

## Steps for option A

1. **Tell Claude** three things: the repository (owner/name), the tool's Supabase project (or an invitation to its organisation), and which tables hold the Zonal Tracker data and how often they change. Neither is visible to this session today.
2. **Data contract.** Claude maps the tool's tables to the tracker model already used by the Upload Centre: report date, team (location), client, target cases, MTD cases, rate / revenue. The contract lists each field, its unit and its checks.
3. **Token.** An admin issues one `ingest` token for the tool, with a label such as "tool name — tracker push", an expiry and an owner. Keep it on the tool's server side only, for example as an Edge Function secret or a GitHub Actions secret. Never put it in front-end code or in the repository.
4. **Push.** The tool's server side calls `POST https://czdjbbhxboweawqbjywr.supabase.co/rest/v1/rpc/bi_ingest` with the public API key in the headers and `{p_token, p_action, p_payload}` in the body. It follows the same batch steps as the Upload Centre (`begin`, pieces of at most 300 rows, `commit`) and retries a piece that times out.
5. **Parallel run (one week).** Keep uploading the tracker by hand as well. Claude adds a Data Health check that compares the tool's batch with the manual upload for the same report date; this check is not built yet. Switch off the manual upload only when they agree.
6. **Operate.** Batches from the tool show as `ingest-token: <label>` in the audit log. If the tool misbehaves, revoke its token (`bi.ingest_token.revoked = true`) and reject its batches; nothing else is affected.

## Rules that stay in force

- Do not put service-role keys or admin tokens in front-end code or in any repository.
- Do not commit business data or names to GitHub.
- Do not send personal data to AI providers.
- Load the data through `bi_ingest` only. Writing directly into `bi` tables skips the checks, the audit trail and the cache refresh.

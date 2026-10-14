# Known limitations register

| # | Limitation | Impact | Mitigation / next step |
|---|---|---|---|
| L1 | Point Wise now to Oct-2026 except Kolhapur-Vinayak (Jul only) and Lucknow/Kolkata (no new files); Case Wise ends Oct-2026 (some groups earlier) | Field metrics missing for those groups after their last file | Upload their files; freshness shown per group |
| L2 | No Case Wise files for Amaravati, Jalgaon, Solapur, Nanded, Punjab (partly), Bihar/Patna, Goa (via Mumbai only) | ~4,100 Oct cases cannot be compared with Force | Shown as "not received", never as 0% Force |
| L3 | Case Wise cannot distinguish BOM MSME PRE/POST, SBI Car Loan+ | Force usage only at client-family level | Need a product/sub-client field in Force export |
| L4 | Route is rule-based (D17), not an explicit source flag | Manual share may be overstated if back-office staff submit field points in-app | Validate with Ops; a Force submission-channel flag would make it exact |
| L5 | Tracker expense block (L/M/N) inconsistent; "YTD" is not YTD | Expense metrics not used in KPIs | Business to define; values preserved raw |
| L6 | Historical tracker targets not in source | No historical achievement % | — |
| L7 | 2,425 negative case TATs (mostly Guwahati), 1,353 points without a Case Wise case | Excluded / counted at point level only | Logged in `bi.dq_exception` |
| L8 | **Storage: DB 388 MB of the 500 MB free tier (14-Oct)** — point_store 186 MB (751,902 points, ~92k dead tuples from re-uploads), point_derived 86 MB, stg_row 19 MB bloat. Point Wise adds ~110k points ≈ 40 MB/month | **~3 months of headroom** | Short term: `VACUUM FULL bi.point_store, bi.stg_row` (~30–40 MB); then either archive points older than 18 months or move to Supabase Pro (8 GB). Decision needed |
| L9 | Dashboard is public (anyone with the link can read business figures and employee names) | Business decision | `noindex`; rotate the link by renaming the repo if it leaks; admin functions need the key |
| L13 | Anonymous API calls can be repeated by anyone (no rate limit) | Possible load spikes | Result cache absorbs repeats; Supabase rate limits apply |
| L10 | Browser upload uses SheetJS 0.20.3 (inlined in artifact build) | — | Keep pinned; files from trusted internal sources only |
| L11 | 1-Jul, 1-Sep, 1-Oct snapshots have no targets yet; 6–17 Jul and 1/3/4/5-Sep source totals disagree with leaf rows | Pan-India totals in those files unreliable | Leaf rows used; mismatches logged |
| L12 | Udyam classification conflicts with brief | Possible misclassification of 1,189 points | Admin review in Data quality |
| L14 | WEF group editing and LFL need migrations bi_036/bi_037 (pending approval) | Editor and LFL show "not available yet" | Apply `supabase/pending/*.sql` in order |
| L15 | Branch universe = branches seen in Force1; no verified branch master | No coverage %, no never-activated branches | Supply client branch master (bi.client_branch_master) |
| L16 | No workforce master (joining/exit dates) | Attrition not computed | Supply HR master |
| L17 | Ask Crux narrative needs GEMINI_API_KEY (not set) | Answers are the deterministic SQL text | Set the Edge Function secret; budget cap via GEMINI_DAILY_CAP |
| L18 | Two interrupted loader batches (#361, #366) remain "staged" | None (data reloaded in later batches) | Mark rejected when DB writes are approved |

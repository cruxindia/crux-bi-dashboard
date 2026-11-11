# Premium experience audit — 11-Nov-2026 (wave 106)

**Brief (owner, 11-Nov-2026 13:01 IST):** "audit to make sure we are giving a premium and luxury feel and experience in the dashboard to the users, just the way dashboards of Fortune companies give. As now the dashboard feels very cluttered and overwhelming to take in so much information at a time."

**Audience and job.** Crux management (MD, zonal and branch managers, the operations and growth lead) opening the dashboard to answer one question first — *where does the month stand, where is the gap, and what do we do today?* — and only then going deeper.

## 1. What made it feel cluttered (measured 11-Nov, before the change, 1440 × 900, every viewer page)

| Measure | Executive overview | All 11 viewer pages |
|---|---:|---:|
| Page height | 5,064 px | 30,277 px |
| Visible words | 2,631 | 29,225 (16,708 of them in the Zonal Tracker replica) |
| Explanatory notes / their words | 36 / 738 | 186 / 3,208 |
| Separate bordered boxes | 121 | 570 |
| Buttons | 70 | 421 |
| Distinct font sizes | 17 | up to 17 per page |

Findings:
1. **Everything open at once.** The Overview showed eleven sections in full (briefing, at a glance, zones, plan, operations and collections, branch managers, period comparison, operations pulse, daily additions, what needs attention, opportunities). Two sections that were meant to start folded (period comparison, plan) did not, because their heading sits in a header row with controls — a folding bug.
2. **Explanations printed in full** above most blocks (method notes of 3–6 lines), so the reader meets text before figures.
3. **Boxes inside boxes**: every tile a separate bordered card inside a bordered card; zone tiles filled edge to edge with red / green / amber washes, which made the zone map the loudest thing on the page.
4. **Shouting labels**: tile labels in capitals with letter-spacing; several sizes of bold numbers competing with the headline figure.
5. **Controls everywhere**: an Ask Crux pill on every tile, table and chart, always visible (wave 105h) — useful, but 30+ pills on the Overview alone.

## 2. Design system adopted ("assurance navy & brass")
- **Palette:** ink `#142338` (text and figures), sapphire `#1F4C8F` (brand, actions, achieved bars), brass `#B08130` (targets, pace and projection markers — the one accent), canvas `#F5F6F8`, panel `#FFFFFF`, hairline `#E3E7ED`, muted `#5F6B7A`; status green `#2E7356` and red `#A8433A` used only for meaning (gains, losses, risk). A matching dark palette.
- **Type:** IBM Plex Sans for text and IBM Plex Sans Condensed for figures — an institutional, banking-grade face with tabular figures. Sentence-case labels; page title 24 px, section 16 px, body 14 px, notes 12.5 px, headline figure 52 px.
- **Layout:** content centred at 1440 px with generous margins; one headline figure per page (the bold element); KPI tiles joined into a single "statement strip" with hairline dividers instead of separate boxes; sections separated by space and a single hairline; secondary sections shown as a quiet list of folded topics.
- **Principles:** figures before explanations; colour only where it carries meaning; one accent; explanations on demand; controls appear where the pointer is.

## 3. What changed
| Area | Change |
|---|---|
| Type and colour | New palette and IBM Plex type across the app (light and dark); calmer charts (small legend keys, light grid, rounded bars, thin lines). |
| KPI tiles | One strip with hairline dividers; sentence-case labels; notes limited to three lines; two tiles per row on phones. |
| Zone map | Neutral tiles with a coloured top bar (stronger = further from the yardstick) and a faint wash, instead of full-tile colour. Same meaning, same legend. |
| Information diet | Overview opens with the hero, the KPI strip, the briefing notes, "At a glance" and the zone map; plan, operations and collections, branch managers, period comparison, operations pulse, daily additions, what needs attention and opportunities start folded. Analysis pages open their first three sections and fold the rest while the page loads. A user's own open / close choice is remembered and always wins. |
| Explanations | Notes and introductions longer than two lines show two lines and "More" (warnings, notes in tables, tiles and pop-ups stay whole). |
| Folding bug | Sections whose heading sits in a header row (title + controls) now fold their content. |
| Ask Crux buttons | Still on every tile, table and chart, but shown when the pointer is over that element (or it has keyboard focus); on touch screens a small round icon that is always visible. |
| Header and banner | Translucent top bar; the stale-data banner is a calm panel with a brass edge. |
| Unchanged on purpose | The Business tracker table keeps the exact Zonal Tracker (Excel) look the owner asked for; the Management summary keeps its print layout. |

## 4. Result (11-Nov, live, same pages and viewport)
| Measure | Overview before | Overview after | Change |
|---|---:|---:|---:|
| Page height | 5,064 px | 3,190 px | −37 % |
| Visible words | 2,631 | 1,552 | −41 % |
| Explanatory notes / words | 36 / 738 | 14 / 315 | −61 % / −57 % |
| Bordered boxes | 121 | 81 | −33 % |
| Buttons | 70 | 47 | −33 % |
| Font sizes | 17 | 13 | −4 |

All 11 viewer pages: height 30,277 → 26,887 px (−11 %); words outside the tracker replica 12,517 → 10,196 (−19 %); bordered boxes 570 → 416 (−27 %); buttons 421 → 351 (−17 %). Nothing was removed: every figure, table and chart is one click away (open a section, "More", or hover for Ask Crux).

Screenshots: before / after of the Overview, a phone view and the dark theme are in the test evidence (scratchpad `w106/`), not in the repository.

## 5. Next steps (recommended, not done in this wave)
1. **Revenue & collections**: the four comparison cards each carry 8–10 lines of reconciliation detail; move the detail into the drill-down and keep one figure + one line per card.
2. **Growth & trends**: 15 cards on one page; split into two tabs (movement, comparison) like People.
3. **Insight lists** ("Doing well / carried by a few / needs attention"): show the top three per list with "show all".
4. **Daily briefing**: show the headline and the three actions first, the zone table behind "Show all" (today the first screen of the notes is the zone table).
5. Re-measure after each step with `ux_measure.py` (same pages, same viewport) and keep the Overview under 3,500 px.

Decisions: D305–D312 in SOW.md. Tests: TEST_REPORT.md, wave 106.

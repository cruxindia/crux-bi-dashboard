# Test note — weekly improver — unit counts on the Executive overview (14-Nov-2026)
| Test | What | Result |
|---|---|---|
| IMP-UNITS-1 | `python3 tools/build.py` | inline scripts parse OK ✓ |
| IMP-UNITS-2 | Built page served locally against the live database (headless browser, desktop width): Overview shows the "Units by type" card open (not inside a folded section); nothing is loaded until "Show unit counts" is pressed; then the six unit tiles and the by-type table appear, with one heading in the card | ✓, 0 page errors |
| IMP-UNITS-3 | `unitsCard()` keeps its heading by default, so Business tracker → Branches is unchanged | by code review ✓ |

(Kept in its own file so improver pull requests do not conflict with each other in docs/TEST_REPORT.md.)

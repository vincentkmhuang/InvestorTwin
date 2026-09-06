# Phase 2 Sprint 010 — Today Workspace Readability

Acceptance harness for Spec:
`docs/Phase 2 Sprint 010 Today Workspace Readability SPEC.md`

## Tests

| ID | Case |
|---|---|
| A / TEST 112 | 30-second primary path sections present and ordered before supporting |
| A2 / TEST 113 | Primary elevation / reorder (not buried under Global/Taiwan/Upcoming) |
| B / TEST 114 | Hierarchy markers: primary vs supporting bands / roles |
| B2 / TEST 115 | Not cosmetic-only: DOM reorder + dedup-safety code present |
| C / TEST 116 | Secondary repetition softened (shorten / residual) without inventing data |
| D / TEST 117 | Section integrity: keepResidual for Yesterday / Global / Taiwan |
| E / TEST 118 | Candidate Attention remains question-first; Pending/Watching path intact |
| F / TEST 119 | Human Gate CTA only (no disposition POST from Attention) |
| G / TEST 120 | No automation of Queue / Card / Conclusion / Decision |
| H / TEST 121 | Canonical `morning-brief.json` path; generate-morning-brief untouched |
| I / TEST 122 | Sprint 001–009 regression PASS |
| J / TEST 123 | Production File Guard PASS |

## Run

```powershell
powershell -NoProfile -File tests/p2-010-today-workspace-readability.ps1
```

Presentation-first only. Quote-as-News Brief content remains a follow-up.

# Phase 2 Sprint 011 — Morning Brief Content Quality

Acceptance harness for Spec:
`docs/Phase 2 Sprint 011 Morning Brief Content Quality SPEC.md`

## Tests

| ID | Case |
|---|---|
| A / TEST 124 | Quote-as-news honesty |
| B / TEST 125 | Yesterday / Executive why-quality |
| C / TEST 126 | Today's 3 Things attention quality |
| D / TEST 127 | Upcoming stale-event removal |
| E / TEST 128 | WTI / Brent / VIX Market Temperature mapping |
| F / TEST 129 | Bitcoin / Gold remain missing without Evidence |
| G / TEST 130 | Cross-section duplication reduction |
| H / TEST 131 | Canonical morning-brief.json schema unchanged |
| I–J / TEST 132 | Sprint 008–009 contracts untouched in this sprint |
| K / TEST 133 | Sprint 001–010 regression PASS |
| L / TEST 134 | Production File Guard PASS |

## Run

```powershell
powershell -NoProfile -File tests/p2-011-morning-brief-content-quality.ps1
```

Content / generator-first. No News DB. No Bitcoin/Gold collectors. No Today redesign.

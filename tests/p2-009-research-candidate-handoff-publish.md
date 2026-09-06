# Phase 2 Sprint 009 — Research Candidate Handoff Publish

Acceptance harness for Spec:
`docs/Phase 2 Sprint 009 Research Candidate Handoff Publish SPEC.md`

## Identity precedence

| Object | Key |
|---|---|
| Candidate / Evaluation | `eventRef` |
| Event | `eventId` |
| News | `id` → `url` (no title similarity) |
| Link | `newsA` + `newsB` + `relation` |

## Tests

| ID | Case |
|---|---|
| A / TEST 102 | integrate output publishes successfully |
| B / TEST 103 | published Candidate appears in Attention path |
| C / TEST 104 | Pending / Watching dispositions preserved |
| D / TEST 105 | Ignored remains hidden after republish |
| E / TEST 106 | repeated publish is idempotent |
| F / TEST 107 | no automatic Gate action |
| G / TEST 108 | no automatic Card / Queue / Conclusion / Thesis / Decision write |
| H / TEST 109 | Sprint 001–008 regression PASS |
| I / TEST 110 | Production File Guard PASS |
| J / TEST 111 | production Research Cards / conclusions / theses unchanged |

## Run

```powershell
powershell -NoProfile -File tests/p2-009-research-candidate-handoff-publish.ps1
```

Publish is opt-in only (`--publish-handoff` or `publish-research-candidates-handoff.py --handoff`).
Ledger is never written by publish.

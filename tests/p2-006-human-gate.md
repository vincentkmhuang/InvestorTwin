# Phase 2 Sprint 006 — Human Gate

Human Gate lives on the existing Research Queue page (`#queue`).

Candidate source:

```
data/research-candidates-handoff.json
```

(Sprint 005 integration output)

Disposition ledger:

```
data/candidate-gate.json
```

API:

```
GET  /api/candidate-gate
POST /api/candidate-gate  { action, eventRef, cardId? }
```

Actions: `ignore` | `watch` | `link` | `queue`

Run acceptance + regression:

```
powershell -File tests/p2-006-human-gate.ps1
```

TEST 65–75 cover Candidate appearance, Ignore / Watch / Link / Queue, traceability, regression, and Production File Guard.

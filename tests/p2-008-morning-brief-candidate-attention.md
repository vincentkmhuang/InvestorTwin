# Phase 2 Sprint 008 — Morning Brief Candidate Attention

Acceptance harness for Spec:
`docs/Phase 2 Sprint 008 News Intelligence Morning Brief Candidate Attention SPEC.md`

## Tests

| ID | Case |
|---|---|
| A / TEST 89 | Pending Candidate appears in Brief/Today Attention |
| B / TEST 90 | Watching Candidate appears |
| C / TEST 91 | Ignored Candidate does not appear |
| D / TEST 92 | Linked Candidate does not appear as pending attention |
| E / TEST 93 | Queued Candidate does not appear as pending attention |
| F / TEST 94 | researchQuestion is primary |
| G / TEST 95 | Importance / Relevance / Impact visible |
| H / TEST 96 | eventRef remains traceable |
| I / TEST 97 | Attention navigates to `#queue` Human Gate |
| J / TEST 98 | No automatic Queue / Card / Conclusion / Thesis / Decision writes |
| K / TEST 99 | 031-B Evidence → Brief structure remains intact |
| L / TEST 100 | Sprint 001–007 regression PASS |
| M / TEST 101 | Production File Guard PASS |

## Run

```powershell
powershell -NoProfile -File tests/p2-008-morning-brief-candidate-attention.ps1
```

Derived Attention only: handoff + candidate-gate ledger. No News/Event/Candidate DB. No Brief redesign.

# Phase 2 Sprint 005 — News → Event → Evaluation Integration

SPEC:

```
docs/Phase 2 Sprint 005 News Event Evaluation Integration SPEC.md
```

Integration entrypoint:

```
python scripts/integrate-news-event-evaluation.py --input tests/fixtures/p2-005-case-a-nvidia-same-event.json
```

Stdout shape:

```
news[] / events[] / evaluations[] / researchCandidates[]
```

The integration reuses `link-news-events.py` then Sprint 001 evaluation helpers. It does not write Brief, Queue, Research Cards, Decisions, or Buy/Sell recommendations.

Run acceptance + regression:

```
powershell -File tests/p2-005-news-event-evaluation-integration.ps1
```

| Case | Expect |
|---|---|
| A | Same Event → 1 Evaluation → 1 Candidate |
| B | Importance 4 / Relevance Low / Medium-Low → Candidate NO |
| C | Same Event + new evidence preserved → 1 Evaluation |
| D | Related Events → Evaluation A + Evaluation B |

TEST 53–64 cover Event-level Evaluation / Candidate identity, evidence preservation, Human Gate, NVIDIA real case, and Production File Guard. Sprint 001–004 regression must remain PASS.

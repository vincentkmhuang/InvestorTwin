# Phase 2 Sprint 004 — News Dedup & Event Linking

SPEC:

```
docs/Phase 2 Sprint 004 News Dedup & Event Linking SPEC.md
```

Engine:

```
python scripts/link-news-events.py --input tests/fixtures/p2-004-case-a-same-event.json
```

The engine prints relations and canonical `eventRef` values. It does not write Brief, Queue, Research Cards, or Decisions. It does not use title similarity.

Run acceptance + regression:

```
powershell -File tests/p2-004-news-dedup-event-linking.ps1
```

| Case | Relation |
|---|---|
| A | Same Event |
| B | Related Event |
| C | Separate Event |
| D | Separate Event |
| E | Same Event |
| F | Related Event |

Event identity is a deterministic canonical key from event type, entities, and event state. It is not `Event-001` by execution order.

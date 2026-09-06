# Phase 2 Sprint 004 — News Dedup & Event Linking Acceptance Cases

This Sprint delivers **SPEC + acceptance cases only**. There is no Dedup engine and no production News / Event store.

SPEC:

```
docs/Phase 2 Sprint 004 News Dedup & Event Linking SPEC.md
```

Cases:

- `tests/fixtures/p2-004-case-a-same-event.json`
- `tests/fixtures/p2-004-case-b-related-event.json`
- `tests/fixtures/p2-004-case-c-separate-event.json`
- `tests/fixtures/p2-004-case-d-same-subject-different-event.json`
- `tests/fixtures/p2-004-case-e-same-event-different-wording.json`
- `tests/fixtures/p2-004-case-f-same-subject-new-information.json`
- `tests/fixtures/p2-004-news-dedup-event-linking.json`

| Case | Relation | Event refs |
|---|---|---|
| A | Same Event | A and B → Event-001 |
| B | Related Event | Event-001 ≠ Event-002 |
| C | Separate Event | Event-001 ≠ Event-002 |
| D | Separate Event | same subject + same date, still not merged |
| E | Same Event | titles differ; core fact matches |
| F | Related Event | announce ≠ complete |

TEST 42–52 are defined in the SPEC. They are not executed in this Sprint because no implementation exists yet.

News Dedup must not use `briefDedupText` or 031-B `(title, researchId)` presentation dedup.

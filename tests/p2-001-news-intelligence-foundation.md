# Phase 2 Sprint 001 — News Intelligence Foundation Acceptance Tests

Run:

```
powershell -File tests/p2-001-news-intelligence-foundation.ps1
```

Fixtures:

- `tests/fixtures/p2-001-case-a-nvidia-huggingface.json`
- `tests/fixtures/p2-001-case-b-ecb-rate-hike.json`
- `tests/fixtures/p2-001-case-c-nasdaq-price-move.json`
- `tests/fixtures/p2-001-case-d-ai-rumor.json`
- `tests/fixtures/p2-001-case-e-ordinary-news.json`
- `tests/fixtures/p2-001-news-nvidia-huggingface.json`
- `tests/fixtures/p2-001-news-malformed-missing-title.json`
- `tests/fixtures/p2-001-news-intelligence-foundation.json`

Engine:

```
python scripts/evaluate-news-intelligence.py --input tests/fixtures/p2-001-case-a-nvidia-huggingface.json
```

The engine only prints an evaluation result. It does not write Brief, Queue, Research Cards, or Decisions.

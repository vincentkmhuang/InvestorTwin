# Phase 2 Sprint 003 — Federal Reserve Official Source Adapter

Run:

```
powershell -File tests/p2-003-federal-reserve-official-adapter.ps1
```

This suite reruns Sprint 001 TEST 1–20 and Sprint 002 TEST 21–30, then TEST 31–41.

Adapter:

```
python scripts/federal-reserve-official-adapter.py --url https://www.federalreserve.gov/newsevents/pressreleases/monetary20260819a.htm
python scripts/federal-reserve-official-adapter.py --url https://www.federalreserve.gov/newsevents/pressreleases/monetary20260819a.htm --html tests/fixtures/p2-003-fed-fomc-minutes-20260819.html
```

The adapter prints one Sprint 001 News Object. It does not score Importance / Relevance / Impact / Candidate, and it does not write Brief, Queue, Research Cards, or Decisions.

Fixtures:

- `tests/fixtures/p2-003-fed-fomc-minutes-20260819.html` — offline official-article excerpt
- `tests/fixtures/p2-003-news-fed-fomc-minutes.json` — normalized News Object
- `tests/fixtures/p2-003-fed-missing-title.html` — validation FAIL case

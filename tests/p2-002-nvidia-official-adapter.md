# Phase 2 Sprint 002 — NVIDIA Official Source Adapter

Run:

```
powershell -File tests/p2-002-nvidia-official-adapter.ps1
```

This suite first reruns Sprint 001 TEST 1–20, then TEST 21–30.

Adapter:

```
python scripts/nvidia-official-adapter.py --url https://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/
python scripts/nvidia-official-adapter.py --url https://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/ --html tests/fixtures/p2-002-nvidia-hugging-face.html
```

The adapter prints one Sprint 001 News Object. It does not score Importance / Relevance / Impact / Candidate, and it does not write Brief, Queue, Research Cards, or Decisions.

Fixtures:

- `tests/fixtures/p2-002-nvidia-hugging-face.html` — offline official-article excerpt
- `tests/fixtures/p2-002-news-nvidia-huggingface.json` — normalized News Object
- `tests/fixtures/p2-002-nvidia-missing-title.html` — validation FAIL case

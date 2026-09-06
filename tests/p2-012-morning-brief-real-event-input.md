# Phase 2 Sprint 012 — Morning Brief Real Event Input

Acceptance harness for evaluated Event → thin 031-B adapter → existing Brief items.

## Tests

| ID | Case |
|---|---|
| TEST 135 | Evaluated Event enters Brief |
| TEST 136 | Event maps into existing items[] / attention surfaces |
| TEST 137 | Event does not require Candidate eligibility |
| TEST 138 | Future Event does not enter Yesterday / Brief event surface |
| TEST 139 | Event framing is honest (事件｜); not quote-as-news; not researchQuestion-as-what |
| TEST 140 | Source / eventRef traceability retained |
| TEST 141 | FACT claim preferred; Candidate question not used as event title |
| TEST 147 | Executive (what+why) ≠ Macro Decision Lens (impact observation); omit if not distinct |
| TEST 142 | Market Temperature Evidence path unchanged |
| TEST 143 | Required Brief schema unchanged |
| TEST 144 | Candidate Attention / Gate / Queue / Cards untouched |
| TEST 145 | Sprint 001–011 regression PASS |
| TEST 146 | Production File Guard PASS |

## Run

```powershell
powershell -NoProfile -File tests/p2-012-morning-brief-real-event-input.ps1
```

Temporary roots only. Do not expand News/Event DB or source adapters.

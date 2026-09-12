#!/usr/bin/env python3
# News Collect Foundation — shared Collect runId helper.
#
# Adapters must share this module (sys.modules["news_collect_run_id"]) so the
# process-local sequence stays unique across CNA/FSC/TWSE/MOPS in one pipeline.
from __future__ import annotations

import itertools
from datetime import datetime, timezone

_seq = itertools.count(1)


def make_run_id(when=None):
    """Readable Collect runId that stays unique under same-second bursts.

    Format: run-YYYYMMDDTHHMMSSmmmZ-NNNN
      - UTC wall clock with milliseconds (human-sortable)
      - monotonic 4-digit sequence (unique across adapters in one process)
    """
    dt = when or datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)
    seq = next(_seq)
    ms = int(dt.microsecond) // 1000
    return (
        "run-"
        + dt.strftime("%Y%m%dT%H%M%S")
        + f"{ms:03d}Z"
        + f"-{seq:04d}"
    )

"""Deliberate fault injection for the failing-release demo.

The pipeline sets TRADEOPS_FAULT_RATE on a canary revision. Health endpoints are not
affected, so the revision looks healthy to the platform and only canary analysis on real
business requests catches it.
"""

from __future__ import annotations

import asyncio
import random

from tradeops.config import Settings


class InjectedFaultError(RuntimeError):
    pass


class FaultInjector:
    def __init__(self, settings: Settings, rng: random.Random | None = None) -> None:
        self._rate = settings.fault_rate
        self._latency_s = settings.fault_latency_ms / 1000
        # Fault injection is chaos testing, not cryptography.
        self._rng = rng or random.Random()  # nosec B311

    @property
    def enabled(self) -> bool:
        return self._rate > 0 or self._latency_s > 0

    async def maybe_fail(self) -> None:
        if self._latency_s:
            await asyncio.sleep(self._latency_s)
        if self._rate and self._rng.random() < self._rate:
            raise InjectedFaultError("injected fault (TRADEOPS_FAULT_RATE)")

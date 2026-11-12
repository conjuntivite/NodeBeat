"""Histórico (zset por MK/sede) e estado do painel no Redis. Requer decode_responses=True."""
from __future__ import annotations

import json
import time

from .rules import Event

DIA = 86400
RETENCAO = 90 * DIA


async def record(r, ev: Event) -> None:
    key = f"hist:{ev.mk.id}" if ev.mk else "hist:sede"
    score = (ev.fim or ev.inicio).timestamp()
    member = json.dumps(ev.to_payload(), sort_keys=True, ensure_ascii=False)
    await r.zadd(key, {member: score})
    await r.zremrangebyscore(key, "-inf", score - RETENCAO)
    await r.expire(key, RETENCAO)


async def history(r, key: str, days: int = 90, *, now: float | None = None) -> list[dict]:
    now = time.time() if now is None else now
    rows = await r.zrevrangebyscore(f"hist:{key}", "+inf", now - days * DIA)
    return [json.loads(m) for m in rows]


async def save_state(r, mk_id: str, row: dict) -> None:
    await r.set(f"state:mk:{mk_id}", json.dumps(row, ensure_ascii=False))


async def load_states(r) -> dict[str, dict]:
    out: dict[str, dict] = {}
    async for k in r.scan_iter(match="state:mk:*"):
        v = await r.get(k)
        if v is not None:
            out[k.removeprefix("state:mk:")] = json.loads(v)
    return out


async def delete_mk(r, mk_id: str) -> None:
    await r.delete(f"hist:{mk_id}", f"state:mk:{mk_id}")

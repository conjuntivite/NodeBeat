"""Fila persistente e ordenada do webhook (Redis) + sender com backoff."""
from __future__ import annotations

import asyncio
import json

import httpx

QUEUE = "queue:webhook"
BASE, TETO = 5, 300


async def enqueue(r, payload: dict) -> None:
    await r.rpush(QUEUE, json.dumps(payload, ensure_ascii=False))


async def pending_count(r) -> int:
    return await r.llen(QUEUE)


async def deliver_once(r, client: httpx.AsyncClient, url: str, token: str | None) -> bool:
    head = await r.lindex(QUEUE, 0)
    if head is None:
        return True
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    try:
        resp = await client.post(url, json=json.loads(head), headers=headers)
    except httpx.HTTPError:
        return False
    if not resp.is_success:
        return False
    # ponytail: LINDEX+LPOP não é atômico; vale só com um único sender (um worker)
    await r.lpop(QUEUE)
    return True


async def run_sender(r, client, url, token, sleep=asyncio.sleep) -> None:
    delay = BASE
    while True:
        if await deliver_once(r, client, url, token):
            delay = BASE
            if await pending_count(r):
                continue
            await sleep(BASE)
        else:
            await sleep(delay)
            delay = min(delay * 2, TETO)

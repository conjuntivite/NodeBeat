"""Sondas de rede: ping (binário Linux, roda no container) e referência HTTPS."""
from __future__ import annotations

import asyncio
import ipaddress

import httpx


async def ping(ip: str) -> bool:
    try:
        ipaddress.ip_address(ip)  # nunca deixa algo como "-c" chegar no argv
    except ValueError:
        return False
    try:
        p = await asyncio.create_subprocess_exec(
            "ping", "-n", "-c", "2", "-W", "1", ip,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    except FileNotFoundError:
        return False
    return await p.wait() == 0


async def reference_ok(host: str, *, transport: httpx.AsyncBaseTransport | None = None) -> bool:
    try:
        async with httpx.AsyncClient(timeout=5, transport=transport) as c:
            await c.head(f"https://{host}", follow_redirects=False)
    except httpx.HTTPError:
        return False
    return True

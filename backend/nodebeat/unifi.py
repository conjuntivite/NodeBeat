"""Leitura de switches e clientes pela API clássica do controlador UniFi Network.

A chave de API é segredo: nunca vai para log, mensagem de erro nem repr.
"""
from __future__ import annotations

from typing import Any

import httpx


class UnifiErro(Exception):
    """Falha ao falar com o controlador; a mensagem é genérica de propósito (sem URL nem chave)."""


def _num(v: Any) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _arred(v: Any) -> float | None:
    n = _num(v)
    return None if n is None else round(n, 1)


def _int(v: Any) -> int | None:
    n = _num(v)
    return None if n is None else int(n)


def _mbps(v: Any) -> float | None:
    n = _num(v)
    return None if n is None else round(n * 8 / 1e6, 1)


def _porta(p: dict, uplink_idx: int | None) -> dict:
    return {
        "poe_w": _arred(p.get("poe_power")), "poe_classe": p.get("poe_class"),
        "rx_mbps": _mbps(p.get("rx_bytes-r")), "tx_mbps": _mbps(p.get("tx_bytes-r")),
        "erros": int((_num(p.get("rx_errors")) or 0) + (_num(p.get("tx_errors")) or 0)),
        "descartes": int((_num(p.get("rx_dropped")) or 0) + (_num(p.get("tx_dropped")) or 0)),
        "stp": p.get("stp_state"), "quedas_link": _int(p.get("link_down_count")),
        "uplink": bool(p.get("is_uplink")) or p.get("port_idx") == uplink_idx,
        "aparelhos": len(p["mac_table"]) if isinstance(p.get("mac_table"), list) else None,
        "clientes": [],
    }


def parse_switch(dev: dict) -> dict:
    up = dev.get("uplink") if isinstance(dev.get("uplink"), dict) else None
    up_idx = _int(up.get("port_idx")) if up else None
    portas = [p for p in dev.get("port_table") or [] if isinstance(p.get("port_idx"), int)]
    poe = [w for w in (_num(p.get("poe_power")) for p in portas) if w is not None]
    stats = dev.get("system-stats") or {}
    return {
        "ip": dev.get("ip"), "mac": dev.get("mac"), "nome": dev.get("name"), "modelo": dev.get("model"),
        "sistema": {
            "modelo": dev.get("model"), "firmware": dev.get("version"), "atualizacao": bool(dev.get("upgradable")),
            "uptime_s": _int(dev.get("uptime")), "cpu": _arred(stats.get("cpu")), "mem": _arred(stats.get("mem")),
            "temperatura": _arred(dev.get("general_temperature")),
            "poe_usado_w": round(sum(poe), 1) if poe else None, "poe_max_w": _arred(dev.get("total_max_power")),
            "clientes": _int(dev.get("num_sta")),
            "uplink": {"porta": up_idx, "remoto": up.get("uplink_mac"), "remoto_porta": _int(up.get("uplink_remote_port"))}
            if up and up_idx is not None else None,
        },
        "portas": {str(p["port_idx"]): _porta(p, up_idx) for p in portas},
    }


def clientes_com_fio(sta: list[dict]) -> dict[str, dict[int, list[dict]]]:
    out: dict[str, dict[int, list[dict]]] = {}
    for c in sta:
        if not c.get("is_wired") or not c.get("sw_mac") or not isinstance(c.get("sw_port"), int):
            continue
        mac = c.get("mac") or ""
        nome = c.get("hostname") or c.get("name")
        out.setdefault(c["sw_mac"].lower(), {}).setdefault(c["sw_port"], []).append({
            "nome": None if not nome or nome.lower() == mac.lower() else nome,
            "ip": c.get("ip") or c.get("last_ip"), "mac": mac, "fabricante": c.get("oui") or None,
            "mbps": _int(c.get("wired-rate_mbps"))})
    for portas in out.values():
        for lista in portas.values():
            lista.sort(key=lambda x: ((x["nome"] or "").lower(), x["ip"] or ""))
    return out


async def ler(client: httpx.AsyncClient, url: str, chave: str, caminho: str, corpo: dict | None = None) -> Any:
    """GET (sem corpo) ou POST (com corpo); devolve `data` quando houver."""
    try:
        r = await client.request("POST" if corpo is not None else "GET", url.rstrip("/") + caminho,
                                 headers={"X-API-Key": chave}, json=corpo)
        r.raise_for_status()
        j = r.json()
    except (httpx.HTTPError, ValueError):
        raise UnifiErro("UniFi não respondeu") from None  # sem encadear: a causa traz URL
    return j["data"] if isinstance(j, dict) and "data" in j else j

"""Leitura de switches e clientes pela API clássica do controlador UniFi Network.

A chave de API é segredo: nunca vai para log, mensagem de erro nem repr.
"""
from __future__ import annotations

import math
import re
from datetime import datetime, timezone
from typing import Any

import httpx


class UnifiErro(Exception):
    """Falha ao falar com o controlador; a mensagem é genérica de propósito (sem URL nem chave)."""


def _num(v: Any) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    try:
        n = float(v)
    except (TypeError, ValueError):
        return None
    return n if math.isfinite(n) else None


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
        "up": bool(p.get("up")), "poe_w": _arred(p.get("poe_power")), "poe_classe": p.get("poe_class"),
        "rx_mbps": _mbps(p.get("rx_bytes-r")), "tx_mbps": _mbps(p.get("tx_bytes-r")),
        "erros": int((_num(p.get("rx_errors")) or 0) + (_num(p.get("tx_errors")) or 0)),
        "descartes": int((_num(p.get("rx_dropped")) or 0) + (_num(p.get("tx_dropped")) or 0)),
        "stp": p.get("stp_state"), "quedas_link": _int(p.get("link_down_count")),
        "uplink": bool(p.get("is_uplink")) or p.get("port_idx") == uplink_idx,
        "aparelhos": _int(p.get("mac_table_count")),
        "clientes": [],
    }


def parse_switch(dev: dict) -> dict:
    up = dev.get("uplink") if isinstance(dev.get("uplink"), dict) else None
    up_idx = _int(up.get("port_idx")) if up else None
    portas = [p for p in dev.get("port_table") or [] if isinstance(p.get("port_idx"), int)]
    poe = [w for w in (_num(p.get("poe_power")) for p in portas) if w is not None]
    stats = dev.get("system-stats") or {}
    usado = _arred(dev.get("total_used_power"))
    if usado is None and poe:
        usado = round(sum(poe), 1)
    return {
        "ip": dev.get("ip"), "mac": dev.get("mac"), "nome": dev["name"] if isinstance(dev.get("name"), str) else None, "modelo": dev.get("model"),
        "sistema": {
            "modelo": dev.get("model"), "firmware": dev.get("version"), "atualizacao": bool(dev.get("upgradable")),
            "uptime_s": _int(dev.get("uptime")), "cpu": _arred(stats.get("cpu")), "mem": _arred(stats.get("mem")),
            "temperatura": _arred(dev.get("general_temperature")),
            "poe_usado_w": usado, "poe_max_w": _arred(dev.get("total_max_power")) or None,  # 0 = switch sem PoE
            "clientes": _int(dev.get("num_sta")),
            "uplink": {"porta": up_idx, "remoto": up.get("uplink_device_name"), "remoto_porta": _int(up.get("uplink_remote_port"))}
            if up and up_idx is not None else None,
        },
        "portas": {str(p["port_idx"]): _porta(p, up_idx) for p in portas},
    }


def retrato(eq_id: str, sw: dict, em: datetime) -> dict:
    """Foto enxuta do switch para o histórico; `sw` é a saída de parse_switch."""
    sis, portas = sw["sistema"], sw["portas"]
    soma = lambda c: round(sum(p[c] or 0 for p in portas.values()), 1)  # noqa: E731  (None conta como 0)
    return {
        "eq_id": eq_id, "em": em, "poe_usado_w": sis["poe_usado_w"], "poe_max_w": sis["poe_max_w"],
        "clientes": sis["clientes"], "temperatura": sis["temperatura"], "cpu": sis["cpu"], "mem": sis["mem"],
        "portas_total": len(portas), "portas_em_uso": sum(1 for p in portas.values() if p["up"]),
        "rx_mbps": soma("rx_mbps"), "tx_mbps": soma("tx_mbps"),
        "portas": {i: {k: p[k] for k in ("up", "rx_mbps", "tx_mbps", "poe_w")} for i, p in portas.items()},
    }


def clientes_com_fio(sta: list[dict]) -> dict[str, dict[int, list[dict]]]:
    out: dict[str, dict[int, list[dict]]] = {}
    for c in sta:
        if not c.get("is_wired") or not isinstance(c.get("sw_mac"), str) or not c["sw_mac"] or not isinstance(c.get("sw_port"), int):
            continue
        mac = c.get("mac") if isinstance(c.get("mac"), str) else ""
        nome = c.get("hostname") or c.get("name")
        nome = nome if isinstance(nome, str) else None
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


TIPOS = {"CLIENT_CONNECTED_WIRED": "cliente_conectou", "CLIENT_DISCONNECTED_WIRED": "cliente_desconectou",
         "DEVICE_UNREACHABLE": "inalcancavel", "MULTIPLE_DEVICES_UNREACHABLE": "inalcancavel",
         "DEVICE_RECONNECTED": "reconectou", "DEVICE_RECONNECTED_WITH_DOWNLINKS": "reconectou",
         "POWER_SUPERVISOR_POWER_CYCLE_TRIGGERED": "poe_religado", "PORT_TRANSMISSION_ERRORS": "erros_transmissao",
         "MADE_CHANGES": "mudanca_admin", "CLIENT_IP_CONFLICT": "conflito_ip"}
GRUPOS = {"cliente_conectou": "clientes", "cliente_desconectou": "clientes", "inalcancavel": "alertas",
          "reconectou": "alertas", "erros_transmissao": "alertas", "conflito_ip": "alertas",
          "poe_religado": "poe", "mudanca_admin": "mudancas", "outro": "alertas"}


_MAC = re.compile(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")


def _params(ev: dict) -> dict[str, dict]:
    p = ev.get("parameters")
    return {k: v for k, v in p.items() if isinstance(v, dict)} if isinstance(p, dict) else {}


def _pn(p: dict, chave: str) -> str | None:
    n = p.get(chave, {}).get("name")
    return n if isinstance(n, str) and n else None


def switch_do_evento(ev: dict, switches: list[dict]) -> dict | None:
    p = _params(ev)
    ids = {str(v["id"]).lower() for v in p.values() if v.get("id")}
    nomes = {_pn(p, "DEVICE"), _pn(p, "OBJECT")} - {None}
    com_porta = _pn(p, "DEVICE_WITH_PORT") or ""
    for sw in switches:
        if sw["mac"] in ids or sw["nome"] in nomes or (com_porta.startswith(sw["nome"] + " ")):
            return sw
    return None


def _mensagem(tipo: str, ev: dict, p: dict, c: dict) -> str:
    porta, cli = c["porta"], c["cliente"] or "Cliente"
    if tipo == "cliente_conectou":
        vel = _pn(p, "CONNECTION_SPEED")
        return f"{cli} conectou" + (f" na porta {porta}" if porta is not None else "") + (f" ({vel})" if vel else "")
    if tipo == "cliente_desconectou":
        partes = [f"{cli} desconectou" + (f" da porta {porta}" if porta is not None else ""), c["duracao"]]
        if c["dados_down"] or c["dados_up"]:
            partes.append(" ".join(x for x in (c["dados_down"] and f"↓ {c['dados_down']}", c["dados_up"] and f"↑ {c['dados_up']}") if x))
        return " · ".join(x for x in partes if x)
    if tipo == "inalcancavel":
        return "Switch inalcançável"
    if tipo == "reconectou":
        return "Switch reconectou"
    if tipo == "poe_religado":
        return "PoE religado automaticamente" + (f" na porta {porta}" if porta is not None else "")
    if tipo == "erros_transmissao":
        return "Erros de transmissão" + (f" na porta {porta}" if porta is not None else "")
    if tipo == "mudanca_admin":
        return f"{_pn(p, 'ADMIN') or 'Alguém'} alterou a configuração"
    if tipo == "conflito_ip":
        return "Conflito de IP" + (f": {c['ip']}" if c["ip"] else "")
    return re.sub(r"\{(\w+)\}", lambda m: _pn(p, m[1]) or m[0], ev.get("message_raw") or "")


def evento_unifi(ev: dict, eq_id: str) -> dict:
    p = _params(ev)
    tipo = TIPOS.get(ev.get("event"), "outro")
    ts = _num(ev.get("timestamp"))
    if ts is None:
        raise ValueError("evento sem timestamp numérico")
    try:
        porta = int(_pn(p, "PORT"))
    except (TypeError, ValueError):
        porta = None
    cid = p.get("CLIENT", {}).get("id")
    campos = {"porta": porta, "cliente": _pn(p, "CLIENT") or (cid if isinstance(cid, str) and cid else None),
              "mac": cid.lower() if isinstance(cid, str) and _MAC.fullmatch(cid) else None,
              "ip": _pn(p, "IP"), "duracao": _pn(p, "DURATION"),
              "dados_up": _pn(p, "DATA_UP"), "dados_down": _pn(p, "DATA_DOWN")}
    return {"mk_id": f"eq:{eq_id}", "origem": "unifi", "unifi_id": ev["id"],
            "recebido_em": datetime.fromtimestamp(ts / 1000, timezone.utc),
            "tipo": tipo, "severidade": (ev.get("severity") or "").lower() or None,
            "campos": campos, "mensagem": _mensagem(tipo, ev, p, campos)}

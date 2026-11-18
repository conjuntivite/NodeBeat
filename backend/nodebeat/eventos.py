"""Linhas de syslog das MKs -> evento classificado (puro).

Formato (docs/spike-syslog.md): `topicos mensagem`, sem PRI, data ou hostname.
"""
from __future__ import annotations

import re
from datetime import datetime

TIPOS = ("login", "login_falha", "logout", "config", "interface", "ipsec",
         "dhcp", "pppoe", "reboot", "erro", "outro")

_MAX_BYTES = 2048
_TOPICOS = re.compile(r"[a-z0-9-]+(,[a-z0-9-]+)+")  # ao menos 2: tópico + severidade
_IPV4 = re.compile(r"\d{1,3}(?:\.\d{1,3}){3}")
_PPPOE = re.compile(r"^(?P<interface>[^\s:]+): (?P<estado>\S+)")
_CONFIG = re.compile(
    r"^(?P<objeto>.+?) (?P<acao>added|changed|removed) by "
    r"(?:[\w-]+\((?P<via>\w+)\):)?(?P<usuario>[^@\s/]+)(?:@(?P<ip>[\d.]+))?")

# Ordem importa: a primeira que casar vence.
_REGRAS = [
    ("login", re.compile(r"^user (?P<usuario>\S+) logged in from (?P<ip>[\d.]+) via (?P<via>\S+)")),
    ("login_falha", re.compile(r"^login failure for user (?P<usuario>\S+) from (?P<ip>[\d.]+) via (?P<via>\S+)")),
    ("logout", re.compile(r"^user (?P<usuario>\S+) logged out from (?P<ip>[\d.]+) via (?P<via>\S+)")),
    ("config", _CONFIG),
    ("interface", re.compile(r"^(?P<interface>\S+) link (?P<estado>up|down)\b")),
    ("dhcp", re.compile(r"^(?P<servidor>\S+) assigned (?P<ip>[\d.]+) to (?P<mac>[0-9A-Fa-f:]{17})")),
    ("reboot", re.compile(r"^router rebooted")),
]


def _campos(m: re.Match) -> dict:
    return {k: v for k, v in m.groupdict().items() if v is not None}


def parse(dado: bytes) -> dict:
    texto = dado[:_MAX_BYTES].decode("utf-8", errors="replace").strip()
    primeiro, _, resto = texto.partition(" ")
    if _TOPICOS.fullmatch(primeiro):
        topicos, mensagem = primeiro.split(","), resto.strip()
    else:
        topicos, mensagem = [], texto
    severidade = next((s for t, s in (("critical", "crit"), ("error", "err"),
                                      ("warning", "warning"), ("debug", "debug"))
                       if t in topicos), "info")
    return {"severidade": severidade, "topicos": topicos, "mensagem": mensagem}


def classificar(topicos: list[str], mensagem: str, severidade: str) -> tuple[str, dict]:
    if "ipsec" in topicos:
        m = _IPV4.search(mensagem)
        return "ipsec", {"peer": m.group()} if m else {}
    if "pppoe" in topicos or "ppp" in topicos:
        m = _PPPOE.match(mensagem)
        return "pppoe", _campos(m) if m else {}
    for tipo, rx in _REGRAS:
        m = rx.match(mensagem)
        if m:
            return tipo, _campos(m)
    if severidade in ("crit", "err") or "critical" in topicos or "error" in topicos:
        return "erro", {}
    return "outro", {}


def evento(dado: bytes, mk_id: str, recebido_em: datetime) -> dict:
    p = parse(dado)
    tipo, campos = classificar(p["topicos"], p["mensagem"], p["severidade"])
    return {"mk_id": mk_id, "recebido_em": recebido_em, "severidade": p["severidade"],
            "topicos": p["topicos"], "tipo": tipo, "campos": campos, "mensagem": p["mensagem"]}


def ruido(ev: dict, ip_origem: str | None) -> bool:
    if "debug" in ev["topicos"]:
        return True
    c = ev["campos"]
    return (ev["tipo"] in ("login", "logout") and c.get("usuario") == "monitor"
            and c.get("ip") == ip_origem)

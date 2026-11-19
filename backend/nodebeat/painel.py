"""Painel de eventos: categoria de cada evento e agregações (puro, sem banco)."""
from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass, field

NORMAIS = {"login_ok", "ok"}  # subtipos que aparecem nos blocos mas não entram nas contagens de problema

_FALHA_LOGIN = re.compile(r"login failure for user (\S*) from ([\d.]+) via (\S+)")
_VPN_FALHA = re.compile(r"fail|error|invalid|no suitable|timed? ?out|mismatch|not found", re.I)
_LINK_FISICO = re.compile(r"collision|duplex mismatch", re.I)


@dataclass
class Ctx:
    sede_redes: list[str] = field(default_factory=list)
    ips_sede: list[str] = field(default_factory=list)


_INTERNAS = [ipaddress.ip_network(n) for n in
             ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16")]


def _externo(ip: str, ctx: Ctx) -> bool:
    # Não usa is_global: faixas de documentação (203.0.113.0/24) contam como internet.
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if ip in ctx.ips_sede or any(a in n for n in _INTERNAS):
        return False
    return not any(a in ipaddress.ip_network(r) for r in ctx.sede_redes)


def falha_login(ev: dict) -> tuple[str, str, str] | None:
    """(usuário, ip, via) de uma falha de login, mesmo com usuário vazio (que o classificador deixa em `erro`)."""
    m = _FALHA_LOGIN.search(ev["mensagem"])
    return (m.group(1), m.group(2), m.group(3)) if m else None


def categoria(ev: dict, ctx: Ctx) -> tuple[str, str] | None:
    tipo, msg = ev["tipo"], ev["mensagem"]
    if tipo in ("login_falha", "erro"):
        f = falha_login(ev)
        if f:
            return ("acesso", "falha_externa") if _externo(f[1], ctx) else ("autenticacao", "falha_interna")
    if tipo == "login":
        c = ev["campos"]
        if c.get("usuario") != "monitor" and _externo(c.get("ip", ""), ctx):
            return "acesso", "login_externo_ok"
        return "autenticacao", "login_ok"
    if tipo == "pppoe":
        if "authentication failed" in msg:
            return "autenticacao", "pppoe_auth"
        return ("erros", "pppoe") if ev["severidade"] in ("err", "crit") else None
    if tipo == "ipsec":
        return ("vpn", "falha") if ev["severidade"] in ("err", "crit") or _VPN_FALHA.search(msg) else ("vpn", "ok")
    if tipo == "interface":
        return ("erros", "interface_down") if " link down" in msg else None
    if tipo == "reboot":
        return "erros", "reboot"
    if tipo == "erro":
        return "erros", "erro"
    if _LINK_FISICO.search(msg):
        return "erros", "link_fisico"
    return None

"""Painel de eventos: categoria de cada evento e agregações (puro, sem banco)."""
from __future__ import annotations

import ipaddress
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta

PERIODOS = {"24h": 24, "7d": 168, "30d": 720}
CATEGORIAS = ("acesso", "autenticacao", "vpn", "erros")
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


def _por_mk(contagem: Counter, nomes: dict) -> list[dict]:
    return [{"mk_id": k, "nome": nomes[k], "n": n} for k, n in contagem.most_common()]


def montar(eventos: list[dict], mks: list[dict], ctx: Ctx, agora: datetime, periodo: str,
           mk_id: str | None = None) -> dict:
    if periodo not in PERIODOS:
        raise ValueError(periodo)
    nomes = {m["id"]: m["nome"] for m in mks if not mk_id or m["id"] == mk_id}
    fim = agora.replace(minute=0, second=0, microsecond=0)
    inicio = fim - timedelta(hours=PERIODOS[periodo] - 1)
    serie = {inicio + timedelta(hours=i): dict.fromkeys(CATEGORIAS, 0) for i in range(PERIODOS[periodo])}
    resumo = dict.fromkeys(CATEGORIAS, 0)
    contagens: dict[str, Counter] = defaultdict(Counter)  # mk -> categoria -> n
    por_mk_cat: dict[str, Counter] = {c: Counter() for c in CATEGORIAS}
    sub: dict[str, Counter] = {c: Counter() for c in CATEGORIAS}
    ips, vias = Counter(), Counter()
    logins, vpn_falhas, ifaces = [], [], Counter()

    for ev in eventos:
        if ev["mk_id"] not in nomes or ev["recebido_em"] < inicio:
            continue
        cat = categoria(ev, ctx)
        if not cat:
            continue
        c, st = cat
        sub[c][st] += 1
        if st in NORMAIS:
            continue
        resumo[c] += 1
        por_mk_cat[c][ev["mk_id"]] += 1
        contagens[ev["mk_id"]][c] += 1
        serie[ev["recebido_em"].replace(minute=0, second=0, microsecond=0)][c] += 1
        if st == "falha_externa":
            _, ip, via = falha_login(ev)
            ips[ip] += 1
            vias[via] += 1
        elif st == "login_externo_ok":
            cp = ev["campos"]
            logins.append({"mk_id": ev["mk_id"], "nome": nomes[ev["mk_id"]], "usuario": cp.get("usuario"),
                           "ip": cp.get("ip"), "via": cp.get("via"), "quando": ev["recebido_em"].isoformat()})
        elif st == "falha" and c == "vpn":
            vpn_falhas.append({"mk_id": ev["mk_id"], "nome": nomes[ev["mk_id"]],
                               "quando": ev["recebido_em"].isoformat(), "mensagem": ev["mensagem"]})
        elif st == "link_fisico":
            ifaces[(ev["mk_id"], ev["mensagem"].split(" ", 1)[0])] += 1

    def bloco(c: str, **extra) -> dict:
        return {"total": resumo[c], "por_mk": _por_mk(por_mk_cat[c], nomes), **extra}

    return {
        "periodo": periodo, "gerado_em": agora.isoformat(), "resumo": resumo,
        "serie_hora": [{"hora": h.isoformat(), **v} for h, v in serie.items()],
        "blocos": {
            "acesso": bloco("acesso", top_ips=[{"ip": i, "n": n} for i, n in ips.most_common(10)],
                            por_via=dict(vias.most_common()), logins_externos=logins[::-1]),
            "autenticacao": bloco("autenticacao", por_subtipo=dict(sub["autenticacao"])),
            "vpn": bloco("vpn", por_subtipo=dict(sub["vpn"]), ultimos=vpn_falhas[::-1][:20]),
            "erros": bloco("erros", por_subtipo=dict(sub["erros"]),
                           interfaces=[{"mk_id": m, "nome": nomes[m], "interface": i, "n": n}
                                       for (m, i), n in ifaces.most_common()]),
        },
        "por_mk": [{"mk_id": i, "nome": n, "semaforo": "verde", "motivos": [],
                    "contagens": {c: contagens[i][c] for c in CATEGORIAS}} for i, n in nomes.items()],
        "atencao": [], "incidentes": [], "config": [],
    }

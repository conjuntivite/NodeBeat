"""Painel de eventos: categoria de cada evento e agregações (puro, sem banco)."""
from __future__ import annotations

import ipaddress
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from functools import lru_cache

SILENCIO_H, REBOOTS_24H = 24, 2
FLAP_N, VPN_FALHAS_N, PPPOE_MASSA_N, INCIDENTE_MKS = 3, 3, 10, 3
HABITUAL_FATOR, HABITUAL_MIN = 3, 20
HORA_INI, HORA_FIM = 7, 19
BRT = timezone(timedelta(hours=-3))  # sem zoneinfo: a imagem não tem tzdata
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


@lru_cache(maxsize=8192)  # o parsing de IP dominava (~5 s com 64 mil eventos); os IPs distintos são poucos
def _externo_c(ip: str, sede_redes: tuple, ips_sede: tuple) -> bool:
    # Não usa is_global: faixas de documentação (203.0.113.0/24) contam como internet.
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if ip in ips_sede or any(a in n for n in _INTERNAS):
        return False
    return not any(a in ipaddress.ip_network(r) for r in sede_redes)


def _externo(ip: str, ctx: Ctx) -> bool:
    return _externo_c(ip, tuple(ctx.sede_redes), tuple(ctx.ips_sede))


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
        if ev["mk_id"] not in nomes or not inicio <= ev["recebido_em"] <= agora:  # depois de agora: chegou durante a leitura
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

    todas = {m["id"]: m["nome"] for m in mks}
    por_ev: dict[str, list[dict]] = defaultdict(list)
    for ev in sorted(eventos, key=lambda x: x["recebido_em"]):
        por_ev[ev["mk_id"]].append(ev)
    semaforo, novos_por_mk = {}, {}
    for i in nomes:
        verm, amar, novos = _regras(por_ev[i], ctx, agora)
        semaforo[i] = ("vermelho" if verm else "amarelo" if amar else "verde", verm + amar)
        novos_por_mk[i] = novos
    atencao = sorted(({"mk_id": i, "nome": nomes[i], "semaforo": c, "motivo": "; ".join(m)}
                      for i, (c, m) in semaforo.items() if c != "verde"),
                     key=lambda a: a["semaforo"] != "vermelho")
    incidentes = [{"inicio": x["inicio"].isoformat(), "fim": x["fim"].isoformat(), "sintoma": x["sintoma"],
                   "mks": sorted(todas[m] for m in x["ids"] if m in todas)}
                  for x in _incidentes([e for e in eventos if e["mk_id"] in todas], ctx)
                  if x["inicio"] >= inicio and (not mk_id or mk_id in x["ids"])]
    config = [{"mk_id": e["mk_id"], "nome": nomes[e["mk_id"]], "quando": e["recebido_em"].isoformat(),
               "usuario": e["campos"].get("usuario"), "objeto": e["campos"].get("objeto"),
               "acao": e["campos"].get("acao"),
               "fora_horario": not HORA_INI <= e["recebido_em"].astimezone(BRT).hour < HORA_FIM,
               "usuario_novo": e["campos"].get("usuario") in novos_por_mk[e["mk_id"]]}
              for e in reversed(sorted(eventos, key=lambda x: x["recebido_em"]))
              if e["tipo"] == "config" and e["mk_id"] in nomes and e["recebido_em"] >= inicio]

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
        "por_mk": [{"mk_id": i, "nome": n, "semaforo": semaforo[i][0], "motivos": semaforo[i][1],
                    "contagens": {c: contagens[i][c] for c in CATEGORIAS}} for i, n in nomes.items()],
        "atencao": atencao, "incidentes": incidentes, "config": config,
    }


def _rajada(tempos: list[datetime], n: int, janela: timedelta) -> bool:
    return any(tempos[i + n - 1] - tempos[i] <= janela for i in range(len(tempos) - n + 1))


def _sintoma(c: str, st: str) -> str | None:
    return {"interface_down": "interface_down", "reboot": "reboot", "pppoe": "pppoe"}.get(st) or (
        "vpn_falha" if (c, st) == ("vpn", "falha") else None)


def _usuario(ev: dict) -> str | None:
    return ev["campos"].get("usuario") if ev["tipo"] in ("config", "login", "logout") else None


def _regras(evs: list[dict], ctx: Ctx, agora: datetime) -> tuple[list[str], list[str], set[str]]:
    """(motivos vermelhos, motivos amarelos, usuários novos) de uma MK; `evs` em ordem crescente."""
    d24, d15, h1 = agora - timedelta(hours=24), timedelta(minutes=15), timedelta(hours=1)
    verm, amar = [], []
    rec = [(e, categoria(e, ctx)) for e in evs if e["recebido_em"] >= d24]
    login = next(((e, c) for e, c in rec if c == ("acesso", "login_externo_ok")), None)
    if login:
        cp = login[0]["campos"]
        verm.append(f"Login de fora: {cp.get('usuario')} de {cp.get('ip')} via {cp.get('via')}")
    reboots = sum(1 for _, c in rec if c == ("erros", "reboot"))
    if reboots >= REBOOTS_24H:
        verm.append(f"Reinícios repetidos ({reboots} em 24 h)")
    downs: dict[str, list[datetime]] = defaultdict(list)
    for e, c in rec:
        if c == ("erros", "interface_down"):
            downs[e["mensagem"].split(" ", 1)[0]].append(e["recebido_em"])
    verm += [f"Oscilação em {i}" for i, t in downs.items() if _rajada(t, FLAP_N, h1)]
    if _rajada([e["recebido_em"] for e, c in rec if c == ("vpn", "falha")], VPN_FALHAS_N, h1):
        verm.append("Falhas de VPN repetidas")
    if _rajada([e["recebido_em"] for e, c in rec if c == ("erros", "pppoe")], PPPOE_MASSA_N, d15):
        verm.append("Queda em massa de PPPoE")
    if not evs:
        amar.append("Nunca mandou eventos")
    elif evs[-1]["recebido_em"] < agora - timedelta(hours=SILENCIO_H):
        amar.append("Sem eventos há mais de 24 h")
    primeira: dict[str, datetime] = {}
    for e in evs:
        u = _usuario(e)
        if u:
            primeira.setdefault(u, e["recebido_em"])
    antigo = any(t < d24 for t in primeira.values())
    novos = {u for u, t in primeira.items() if antigo and t >= d24}
    amar += [f"Usuário novo: {u}" for u in sorted(novos)]
    # Acesso externo e PPPoE-auth ficam de fora: são ruído constante da internet/sondas.
    conta = lambda e, c: c and c[0] in ("vpn", "erros") or c == ("autenticacao", "falha_interna")  # noqa: E731
    n24 = sum(1 for e, c in rec if conta(e, c))
    antes = sum(1 for e in evs if agora - timedelta(hours=24 + 168) <= e["recebido_em"] < d24
                and conta(e, categoria(e, ctx)))
    if n24 >= HABITUAL_MIN and n24 > HABITUAL_FATOR * antes / 7:
        amar.append(f"Acima do habitual ({n24} em 24 h, média {antes / 7:.0f}/dia)")
    return verm, amar, novos


def _incidentes(todos: list[dict], ctx: Ctx) -> list[dict]:
    por_sintoma: dict[str, list[tuple[datetime, str]]] = defaultdict(list)
    for e in todos:
        c = categoria(e, ctx)
        if c and (sin := _sintoma(*c)):
            por_sintoma[sin].append((e["recebido_em"], e["mk_id"]))
    out = []
    for sin, lista in por_sintoma.items():
        lista.sort()
        i = 0
        while i < len(lista):
            j = i
            while j + 1 < len(lista) and lista[j + 1][0] - lista[i][0] <= timedelta(minutes=15):
                j += 1
            ids = {m for _, m in lista[i:j + 1]}
            if len(ids) >= INCIDENTE_MKS:
                out.append({"inicio": lista[i][0], "fim": lista[j][0], "sintoma": sin, "ids": ids})
                i = j + 1
            else:
                i += 1
    return sorted(out, key=lambda x: x["inicio"], reverse=True)

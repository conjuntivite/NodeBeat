"""Feed de ataques ao vivo: agrupa falhas/logins externos por (IP, MK, via). Puro, sem banco."""
from __future__ import annotations

from nodebeat import geoip, painel


def agrupar(eventos: list[dict], nomes: dict[str, str], ctx: painel.Ctx, pais_de=geoip.pais,
            max_grupos: int = 200) -> tuple[list[dict], int]:
    grupos: dict[tuple, dict] = {}
    for ev in eventos:
        if ev["mk_id"] not in nomes:
            continue
        cat = painel.categoria(ev, ctx)
        if cat == ("acesso", "falha_externa"):
            _, ip, via = painel.falha_login(ev)
            sucesso, usuario = False, None
        elif cat == ("acesso", "login_externo_ok"):
            ip, via = ev["campos"]["ip"], ev["campos"].get("via", "")
            sucesso, usuario = True, ev["campos"].get("usuario")
        else:
            continue
        # login aceito: o usuário entra na chave (usuários diferentes no mesmo IP não se fundem)
        g = grupos.setdefault((ip, ev["mk_id"], via, sucesso, usuario), {"ip": ip, "mk_id": ev["mk_id"], "via": via, "n": 0,
                                                                 "sucesso": sucesso, "t": ev["recebido_em"], "usuario": usuario})
        g["n"] += 1
        g["t"] = max(g["t"], ev["recebido_em"])
    # ponytail: teto fixo; os mais antigos viram `descartados`
    todos = sorted(grupos.values(), key=lambda g: g["t"], reverse=True)
    saida = []
    for g in todos[:max_grupos][::-1]:
        p = pais_de(g["ip"])
        a = {"ip": g["ip"], "pais": p and p.cc, "pais_nome": p and p.nome, "lat": p and p.lat, "lon": p and p.lon,
             "mk_nome": nomes[g["mk_id"]], "via": g["via"], "n": g["n"], "sucesso": g["sucesso"],
             "quando": g["t"].isoformat()}
        if g["sucesso"]:
            a["usuario"] = g["usuario"]
        saida.append(a)
    return saida, max(0, len(todos) - max_grupos)

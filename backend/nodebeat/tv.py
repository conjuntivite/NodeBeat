"""Respostas públicas da TV: lista fechada de campos, nunca usuário, mk_id nem IP de MK."""
from __future__ import annotations

CAMPOS_ATAQUE = ("ip", "pais", "pais_nome", "lat", "lon", "mk_nome", "via", "n", "sucesso", "quando")
CAMPOS_LOGIN = ("nome", "ip", "pais_nome", "via", "quando")
_CAMPOS_TOP_IP = ("ip", "n", "pais", "pais_nome")


def ataque_publico(a: dict) -> dict:
    return {c: a.get(c) for c in CAMPOS_ATAQUE}


def juntar_publicos(ataques: list[dict]) -> list[dict]:
    """Sem o usuário, grupos que só diferem por ele viram um só (soma n, maior quando)."""
    out: dict[tuple, dict] = {}
    for a in ataques:
        p = ataque_publico(a)
        k = (p["ip"], p["mk_nome"], p["via"], p["sucesso"])
        if k in out:
            out[k]["n"] += p["n"]
            out[k]["quando"] = max(out[k]["quando"], p["quando"])
        else:
            out[k] = p
    return sorted(out.values(), key=lambda g: g["quando"])  # mais antigo primeiro, como ataques.agrupar


def tops_publicos(acesso: dict | None) -> dict:
    if not acesso:
        return {"total": 0, "top_ips": [], "top_paises": [], "por_via": {}, "logins_externos": []}
    return {"total": acesso.get("total", 0),
            "top_ips": [{c: i.get(c) for c in _CAMPOS_TOP_IP} for i in acesso.get("top_ips", [])],
            "top_paises": acesso.get("top_paises", []), "por_via": acesso.get("por_via", {}),
            "logins_externos": [{c: lg.get(c) for c in CAMPOS_LOGIN} for lg in acesso.get("logins_externos", [])]}

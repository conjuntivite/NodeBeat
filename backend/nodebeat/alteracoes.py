"""Alteracoes nas MKs (so escrita pontual, via API-SSL com o usuario nodebeat-rw)."""
from __future__ import annotations

import ipaddress

from librouteros.exceptions import LibRouterosError, TrapError

PEER = "/ip/ipsec/peer"
POLICY = "/ip/ipsec/policy"


def _por_dominio(endereco: str) -> bool:
    try:
        ipaddress.ip_interface(endereco)
        return False
    except ValueError:
        return True


def _sem_prefixo(endereco: str) -> str:
    return endereco.removesuffix("/32")


def ler_peers(api) -> list[dict]:
    return [{"id": p[".id"], "nome": p.get("name"), "endereco": p.get("address", ""),
             "desativado": bool(p.get("disabled")), "comentario": p.get("comment", ""),
             "por_dominio": _por_dominio(p.get("address", ""))} for p in list(api(PEER + "/print"))]


def trocar_peer(api, peer_id: str, novo: str, ao_escrever=None) -> dict:
    """Troca o address do peer. Na v6 (policy sem `peer`) acompanha o sa-dst-address das policies do endereco antigo."""
    peer = next((p for p in list(api(PEER + "/print")) if p[".id"] == peer_id), None)
    if peer is None:
        raise KeyError(peer_id)
    antigo = peer.get("address", "")
    if _sem_prefixo(novo) == _sem_prefixo(antigo):
        raise ValueError("O peer já está com esse endereço")
    # lido antes do set: na v6 o sa-dst-address ainda e o antigo
    policies = [p for p in list(api(POLICY + "/print"))
                if not p.get("template") and not p.get("peer")
                and p.get("sa-dst-address") == _sem_prefixo(antigo)]
    if ao_escrever:
        ao_escrever()  # a partir daqui falha conta como "escrita comecou" (historico)
    try:
        list(api(PEER + "/set", **{".id": peer_id, "address": novo}))
    except TrapError:
        raise
    except (OSError, LibRouterosError):  # conexao caiu durante o set: pode ter aplicado
        return {"nome": peer.get("name"), "antigo": antigo, "novo": novo, "confirmado": False,
                "policies": [], "policies_erro": []}
    feitas: list[str] = []
    erro: list[str] = []
    try:
        for p in policies:
            try:
                list(api(POLICY + "/set", **{".id": p[".id"], "sa-dst-address": novo}))
                feitas.append(p[".id"])
            except TrapError:
                erro.append(p[".id"])
        confirmado = any(p[".id"] == peer_id and p.get("address") == novo for p in list(api(PEER + "/print")))
    except (OSError, LibRouterosError):  # a conexao pode cair depois do set (ex.: o peer era o proprio tunel)
        confirmado = False
    return {"nome": peer.get("name"), "antigo": antigo, "novo": novo, "confirmado": confirmado, "policies": feitas, "policies_erro": erro}

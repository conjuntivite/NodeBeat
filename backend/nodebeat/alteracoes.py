"""Alteracoes nas MKs (so escrita pontual, via API-SSL com o usuario nodebeat-rw)."""
from __future__ import annotations

import ipaddress

from librouteros.exceptions import LibRouterosError, TrapError

from nodebeat import inventario
from nodebeat.routeros import RouterOsError

PEER = "/ip/ipsec/peer"
POLICY = "/ip/ipsec/policy"
NAT = "/ip/firewall/nat"
PREFIXO = "nodebeat:"
_MSG_CAIU = "Conexão caiu durante a alteração; confira as regras nodebeat: na MK"


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


def wan(addresses: list[dict], routes: list[dict], interfaces: set[str], ip_publico: str | None) -> str | None:
    """Interface WAN: a que tem o IP publico; senao a da rota default ativa de menor distance."""
    for a in addresses:
        if ip_publico and not a.get("disabled") and str(a.get("address", "")).split("/")[0] == ip_publico:
            return a.get("interface") if a.get("interface") in interfaces else None
    padrao = [r for r in routes if r.get("dst-address") == "0.0.0.0/0" and r.get("active") and not r.get("disabled")]
    if not padrao:
        return None
    r = min(padrao, key=lambda r: int(r.get("distance") or 255))
    gw, imm, st = str(r.get("gateway") or ""), str(r.get("immediate-gw") or ""), str(r.get("gateway-status") or "")
    for cand in (gw, imm.partition("%")[2], st.rpartition(" via ")[2].strip()):
        if cand in interfaces:
            return cand
    return None


def _grupos_nodebeat(nat_rows: list[dict]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for n in nat_rows:
        c = str(n.get("comment") or "")
        if c.startswith(PREFIXO):
            out.setdefault(c[len(PREFIXO):], []).append(n)
    return out


def liberacoes(nat_rows: list[dict]) -> list[dict]:
    out = []
    for desc, rows in _grupos_nodebeat(nat_rows).items():
        n = rows[0]
        out.append({"descricao": desc, "protocolos": [str(x.get("protocol")) for x in rows],
                    "porta_externa": str(n.get("dst-port")), "ip_interno": n.get("to-addresses"),
                    "porta_interna": str(n.get("to-ports")), "wan": n.get("in-interface"),
                    "desativada": any(bool(x.get("disabled")) for x in rows)})
    return sorted(out, key=lambda x: x["descricao"].casefold())


def ler_liberacoes(api) -> list[dict]:
    return liberacoes(list(api(NAT + "/print")))


def _adicionar(api, protocolos, pedido, iface, ids) -> None:
    for p in protocolos:
        r = list(api(NAT + "/add", chain="dstnat", action="dst-nat", protocol=p, **{"dst-port": str(pedido["porta_externa"])},
                     **{"to-addresses": pedido["ip_interno"], "to-ports": str(pedido["porta_interna"]),
                        "in-interface": iface, "comment": PREFIXO + pedido["descricao"]}))
        ids.append(r[0]["ret"])


def liberar_porta(api, pedido: dict, ip_publico: str | None, reservadas: set[int], ao_escrever=None) -> dict:
    ext, desc = pedido["porta_externa"], pedido["descricao"]
    nat_rows = list(api(NAT + "/print"))
    inv = inventario.montar({"nat": nat_rows, "service": list(api("/ip/service/print"))})
    if ext in reservadas | {s["porta"] for s in inv["servicos"]}:
        raise ValueError(f"A porta {ext} é reservada")
    protocolos = ["tcp", "udp"] if pedido["protocolo"] == "ambos" else [pedido["protocolo"]]
    usos = [u for p in protocolos for u in inventario.conferir_porta(ext, p, inv)["usos"]]
    if usos:
        raise ValueError(f"A porta {ext} já está em uso: " + "; ".join(dict.fromkeys(usos)))
    if desc.casefold() in {d.casefold() for d in _grupos_nodebeat(nat_rows)}:
        raise ValueError("Já existe uma liberação com essa descrição")
    iface = wan(list(api("/ip/address/print")), list(api("/ip/route/print")),
                {i["name"] for i in api("/interface/print")}, ip_publico)
    if iface is None:
        raise ValueError("Não foi possível reconhecer a WAN da MK")
    if ao_escrever:
        ao_escrever()
    ids: list[str] = []
    try:
        _adicionar(api, protocolos, pedido, iface, ids)
    except (OSError, LibRouterosError) as e:
        if isinstance(e, TrapError):
            try:
                for i in ids:
                    list(api(NAT + "/remove", **{".id": i}))
            except (OSError, LibRouterosError):
                raise RouterOsError(_MSG_CAIU)
            raise
        raise RouterOsError(_MSG_CAIU)  # RouterOsError simples: SemConexao refaria tudo por outro caminho
    return {"wan": iface, "regras": ids}


def remover_porta(api, descricao: str, ao_escrever=None) -> int:
    alvo = (PREFIXO + descricao).casefold()
    ids = [n[".id"] for n in list(api(NAT + "/print")) if str(n.get("comment") or "").casefold() == alvo]
    if ids and ao_escrever:
        ao_escrever()
    try:
        for i in ids:
            list(api(NAT + "/remove", **{".id": i}))
    except (OSError, LibRouterosError) as e:
        if isinstance(e, TrapError):
            raise
        raise RouterOsError(_MSG_CAIU)
    return len(ids)
